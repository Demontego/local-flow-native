//! Mic capture via cpal, resampled to 16 kHz mono f32 for the engine.
//!
//! Prefers F32 configs (cpal 0.18 ranks I32 above I16 by default). Surfaces
//! device-lost / xrun to the shell via `on_error`.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{
    Device, ErrorKind, FromSample, Sample, SampleFormat, SampleRate, SizedSample, Stream,
    StreamConfig, SupportedStreamConfig,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

const TARGET_HZ: u32 = 16_000;

pub struct Capture {
    _stream: Stream,
    running: Arc<AtomicBool>,
}

impl Capture {
    pub fn start<F, E>(mut on_samples: F, mut on_error: E) -> Result<Self, String>
    where
        F: FnMut(&[f32]) + Send + 'static,
        E: FnMut(String) + Send + 'static,
    {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or_else(|| "no default input device".to_string())?;
        let supported = pick_input_config(&device)?;
        let sample_rate = supported.sample_rate().0;
        let channels = supported.channels() as usize;
        let sample_format = supported.sample_format();
        let stream_config: StreamConfig = supported.into();
        let running = Arc::new(AtomicBool::new(true));
        let running_flag = Arc::clone(&running);

        let stream = match sample_format {
            SampleFormat::F32 => build_stream::<f32, _, _>(
                &device,
                stream_config,
                sample_rate,
                channels,
                running_flag,
                move |data| on_samples(data),
                move |msg| on_error(msg),
            )?,
            SampleFormat::I16 => build_stream::<i16, _, _>(
                &device,
                stream_config,
                sample_rate,
                channels,
                running_flag,
                move |data| on_samples(data),
                move |msg| on_error(msg),
            )?,
            SampleFormat::U16 => build_stream::<u16, _, _>(
                &device,
                stream_config,
                sample_rate,
                channels,
                running_flag,
                move |data| on_samples(data),
                move |msg| on_error(msg),
            )?,
            SampleFormat::I32 => build_stream::<i32, _, _>(
                &device,
                stream_config,
                sample_rate,
                channels,
                running_flag,
                move |data| on_samples(data),
                move |msg| on_error(msg),
            )?,
            other => return Err(format!("unsupported sample format: {other:?}")),
        };
        stream.play().map_err(|e| format!("play: {e}"))?;
        Ok(Self {
            _stream: stream,
            running,
        })
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
    }
}

/// Prefer F32, then I16, I32, U16. Prefer rates near 16 kHz, then 48/44.1 kHz.
fn pick_input_config(device: &Device) -> Result<SupportedStreamConfig, String> {
    let ranges = device
        .supported_input_configs()
        .map_err(|e| format!("input configs: {e}"))?
        .collect::<Vec<_>>();
    if ranges.is_empty() {
        return device
            .default_input_config()
            .map_err(|e| format!("input config: {e}"));
    }

    const FORMAT_ORDER: [SampleFormat; 4] = [
        SampleFormat::F32,
        SampleFormat::I16,
        SampleFormat::I32,
        SampleFormat::U16,
    ];
    const RATE_ORDER: [u32; 3] = [TARGET_HZ, 48_000, 44_100];

    for format in FORMAT_ORDER {
        let matching: Vec<_> = ranges
            .iter()
            .filter(|r| r.sample_format() == format)
            .cloned()
            .collect();
        if matching.is_empty() {
            continue;
        }
        for &hz in &RATE_ORDER {
            for range in &matching {
                if let Some(cfg) = range.clone().try_with_sample_rate(SampleRate(hz)) {
                    return Ok(cfg);
                }
            }
        }
        // Fall back to the range's default rate for this format.
        if let Some(range) = matching.into_iter().next() {
            return Ok(range.with_max_sample_rate());
        }
    }

    device
        .default_input_config()
        .map_err(|e| format!("input config: {e}"))
}

fn stream_error_message(err: cpal::Error) -> String {
    match err.kind() {
        ErrorKind::Xrun => "Mic buffer overrun — speak a bit slower".into(),
        ErrorKind::DeviceNotAvailable => "Mic disconnected".into(),
        ErrorKind::DeviceChanged => "Mic switched — still listening".into(),
        ErrorKind::PermissionDenied => "Mic permission denied".into(),
        ErrorKind::DeviceBusy => "Mic busy".into(),
        ErrorKind::StreamInvalidated => "Mic stream lost — tap again".into(),
        other => format!("Mic error: {other:?}"),
    }
}

fn build_stream<T, F, E>(
    device: &cpal::Device,
    config: StreamConfig,
    sample_rate: u32,
    channels: usize,
    running: Arc<AtomicBool>,
    mut on_samples: F,
    mut on_error: E,
) -> Result<Stream, String>
where
    T: Sample + SizedSample + Send + 'static,
    f32: FromSample<T>,
    F: FnMut(&[f32]) + Send + 'static,
    E: FnMut(String) + Send + 'static,
{
    let err_fn = move |e| {
        let msg = stream_error_message(e);
        tracing::warn!("cpal: {msg}");
        on_error(msg);
    };
    let stream = device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                if !running.load(Ordering::Relaxed) {
                    return;
                }
                let mono = to_mono_f32(data, channels);
                let resampled = resample_linear(&mono, sample_rate, TARGET_HZ);
                if !resampled.is_empty() {
                    on_samples(&resampled);
                }
            },
            err_fn,
            None,
        )
        .map_err(|e| format!("build_input_stream: {e}"))?;
    Ok(stream)
}

fn to_mono_f32<T>(data: &[T], channels: usize) -> Vec<f32>
where
    T: Sample,
    f32: FromSample<T>,
{
    if channels <= 1 {
        return data
            .iter()
            .copied()
            .map(|s| Sample::to_sample::<f32>(s))
            .collect();
    }
    data.chunks(channels)
        .map(|frame| {
            let sum: f32 = frame
                .iter()
                .copied()
                .map(|s| Sample::to_sample::<f32>(s))
                .sum();
            sum / channels as f32
        })
        .collect()
}

/// Cheap linear resampler — fine for ASR input.
fn resample_linear(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || input.is_empty() {
        return input.to_vec();
    }
    let ratio = from as f64 / to as f64;
    let out_len = ((input.len() as f64) / ratio).floor() as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src = i as f64 * ratio;
        let i0 = src.floor() as usize;
        let i1 = (i0 + 1).min(input.len() - 1);
        let t = (src - i0 as f64) as f32;
        out.push(input[i0] * (1.0 - t) + input[i1] * t);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::stream_error_message;
    use cpal::{Error, ErrorKind};

    #[test]
    fn maps_xrun_and_disconnect() {
        let xrun = stream_error_message(Error::new(ErrorKind::Xrun));
        assert!(xrun.to_lowercase().contains("overrun") || xrun.contains("slower"));
        let gone = stream_error_message(Error::new(ErrorKind::DeviceNotAvailable));
        assert!(gone.to_lowercase().contains("disconnect"));
    }
}

//! Mic capture via cpal, resampled to 16 kHz mono f32 for the engine.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, SizedSample, Stream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub struct Capture {
    _stream: Stream,
    running: Arc<AtomicBool>,
}

impl Capture {
    pub fn start<F>(mut on_samples: F) -> Result<Self, String>
    where
        F: FnMut(&[f32]) + Send + 'static,
    {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or_else(|| "no default input device".to_string())?;
        let config = device
            .default_input_config()
            .map_err(|e| format!("input config: {e}"))?;
        let sample_rate = config.sample_rate().0;
        let channels = config.channels() as usize;
        let running = Arc::new(AtomicBool::new(true));
        let running_flag = Arc::clone(&running);

        let sample_format = config.sample_format();
        let stream_config: cpal::StreamConfig = config.into();
        let stream = match sample_format {
            SampleFormat::F32 => build_stream::<f32, _>(
                &device,
                stream_config,
                sample_rate,
                channels,
                running_flag,
                move |data| on_samples(data),
            )?,
            SampleFormat::I16 => build_stream::<i16, _>(
                &device,
                stream_config,
                sample_rate,
                channels,
                running_flag,
                move |data| on_samples(data),
            )?,
            SampleFormat::U16 => build_stream::<u16, _>(
                &device,
                stream_config,
                sample_rate,
                channels,
                running_flag,
                move |data| on_samples(data),
            )?,
            SampleFormat::I32 => build_stream::<i32, _>(
                &device,
                stream_config,
                sample_rate,
                channels,
                running_flag,
                move |data| on_samples(data),
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

fn build_stream<T, F>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    sample_rate: u32,
    channels: usize,
    running: Arc<AtomicBool>,
    mut on_samples: F,
) -> Result<Stream, String>
where
    T: Sample + SizedSample + Send + 'static,
    f32: FromSample<T>,
    F: FnMut(&[f32]) + Send + 'static,
{
    let err_fn = |e| tracing::error!("cpal stream error: {e}");
    let stream = device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                if !running.load(Ordering::Relaxed) {
                    return;
                }
                let mono = to_mono_f32(data, channels);
                let resampled = resample_linear(&mono, sample_rate, 16_000);
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

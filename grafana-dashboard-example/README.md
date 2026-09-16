# Grafana Dashboard Example

Example dashboard for `srt-xtransmit-prometheus`.

Tested with:

- srt-xtransmit-prometheus v0.1.1
- Grafana 13.0.1
- Prometheus datasource

The dashboard includes:

- native SRT socket statistics (`srt_*`)
- xtransmit payload metrics (`srt_xtransmit_*`)

The xtransmit payload metrics require `--enable-metrics` on both
the sender and receiver.

Import:

`grafana-dashboard-example/srt-xtransmit-prometheus-v0.1.1.json`

into Grafana and select your Prometheus datasource if required.

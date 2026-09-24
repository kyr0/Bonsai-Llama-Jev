# System One probability calibration

`llama-server` can optionally load a v1 calibration artifact produced by
`typed-decision-bench` and apply its scalar temperature to the **final candidate
probability vector** returned by `/v1/systemone`. Background:
[the paper, section 18](https://kyr0.github.io/Bonsai-Llama-Jev/#18-calibration-can-be-added-without-changing-model-weights).

```bash
llama-server ... --systemone-calibration /path/to/run_calibration.json
```

or:

```bash
export LLAMA_ARG_SYSTEMONE_CALIBRATION=/path/to/run_calibration.json
llama-server ...
```

The transform is:

```text
q_i = p_i^(1/T) / sum_j p_j^(1/T)
```

This is argmax-preserving for every finite `T > 0`. Applying it after the
multi-character-label joint probability composition is intentional: it makes
runtime semantics exactly match the benchmark fitter, including requests with
more than 62 options.

The loader fails closed. It requires:

- `schema_version` 1 or 2
- `kind == "typed-decision-temperature-calibration"`
- `method == "temperature_scaling"`
- `scope == "global"` (v1) or `"per_qtype"` (v2)
- `deployable == true`
- `status == "ok"`
- finite `temperature > 0`
- non-empty `source.model`

At request time, `source.model` must equal the loaded server model name. A
mismatch returns a System One invalid-request error rather than silently using a
calibrator fitted for another model/runtime response distribution.

## Schema v2: per-question-type temperatures

A v2 artifact may carry a `temperatures` object mapping question types
(`choice`, `score`, `noul`) to their own fitted temperatures:

```json
{"schema_version": 2, "temperature": 1.146, "temperatures": {"choice": 1.176}, ...}
```

The effective temperature for a question is

```
T = temperatures.get(question_type, temperature)
```

i.e. the type-specific value when present, the global `temperature` otherwise.
Each entry is validated like the global one (numeric, finite, > 0). v1
artifacts behave exactly as before.

Calibration changes only returned probabilities/score/noul/confidence. It does
not change model weights, prompt evaluation, answer argmax, token generation
(there is still none), or ordinary completion endpoints.

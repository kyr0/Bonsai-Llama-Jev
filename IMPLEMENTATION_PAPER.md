# Turning Causal Language Models Into Typed-Decision Engines

_Aron Homberg - Independent Researcher - 2026_

> **Scope.** This document explains the inference method implemented by `kyr0/Bonsai-Llama-Jev`: how an ordinary causal language model (LM) can be exposed as a Jev-like typed-decision engine and System One API service without sampling, without generating an answer sentence, and without changing the model weights.
> 
> The central idea is simple: **stop after prompt evaluation, read the model's native next-token logits for a small set of answer-label tokens, normalize those logits into a categorical distribution, and reduce that distribution into a typed result.**
> 
> This is an **inference/readout transformation**, not a new neural architecture and not, by itself, a calibration method. It reproduces the *shape* of a typed-decision API. It does **not** establish that the loaded model has Jev's weights, training procedure, or probability calibration.

## Abstract

Any causal language model already computes a categorical score over its vocabulary at every next-token boundary; a Jev-like typed-decision engine turns runtime-defined semantic answers into token verbalizers, stops inference after prefill, reads only those native logits, converts them with stable restricted softmax and chain-rule branch scoring, and deterministically reduces the resulting distribution into `choice`, `score`, or `noul` — **without sampling and without generating an answer token**. This paper breaks this method down. It explains, how any causal language model can be turned into a Type-Decision Engine. Demonstrated as a paper with code, the target audience of this paper is primarily: Applied AI engineers, AI research scientists and curious tech-affine readers.

---- 

## Table of Contents 

- [1. Provenance](#1-provenance)
- [2. Terminology and abbreviations](#2-terminology-and-abbreviations)
- [3. What is actually being transformed?](#3-what-is-actually-being-transformed)
	- [LM head and next-token distribution](#lm-head-and-next-token-distribution)
- [4. The system-level transformation](#4-the-system-level-transformation)
- [5. Generation vs. typed decision readout](#5-generation-vs-typed-decision-readout)
	- [5.1 Ordinary autoregressive generation](#51-ordinary-autoregressive-generation)
	- [5.2 Typed decision mode](#52-typed-decision-mode)
	- [“No sampling” does not imply bitwise determinism](#no-sampling-does-not-imply-bitwise-determinism)
- [6. Turning semantic answers into token labels](#6-turning-semantic-answers-into-token-labels)
- [7. The critical tokenizer invariant](#7-the-critical-tokenizer-invariant)
- [8. Restricted softmax: the central identity](#8-restricted-softmax-the-central-identity)
	- [Why it is exactly the native LM distribution conditioned on allowed labels](#why-it-is-exactly-the-native-lm-distribution-conditioned-on-allowed-labels)
	- [What the existing unit test proves](#what-the-existing-unit-test-proves)
- [9. Numerical stability: subtract the maximum logit](#9-numerical-stability-subtract-the-maximum-logit)
- [10. Worked one-token example](#10-worked-one-token-example)
	- [11. Factorized multi-character labels](#11-factorized-multi-character-labels)
	- [Why additional model evaluations are necessary](#why-additional-model-evaluations-are-necessary)
	- [Important semantic nuance](#important-semantic-nuance)
- [12. Readout-count complexity](#12-readout-count-complexity)
- [13. KV-cache reuse makes prefix branches cheap](#13-kv-cache-reuse-makes-prefix-branches-cheap)
- [14. Generalizing to arbitrary token verbalizers](#14-generalizing-to-arbitrary-token-verbalizers)
- [15. Typed reducers](#15-typed-reducers)
	- [15.1 Choice](#151-choice)
	- [15.2 Score](#152-score)
	- [15.3 Noul](#153-noul)
- [16. The confidence field is a local heuristic](#16-the-confidence-field-is-a-local-heuristic)
- [17. Conditional option probabilities are not automatically calibrated probabilities](#17-conditional-option-probabilities-are-not-automatically-calibrated-probabilities)
- [18. Calibration can be added without changing model weights](#18-calibration-can-be-added-without-changing-model-weights)
	- [Sampling temperature vs. calibration temperature](#sampling-temperature-vs-calibration-temperature)
- [19. Prompt construction is part of the effective model](#19-prompt-construction-is-part-of-the-effective-model)
	- [Candidate order can matter](#candidate-order-can-matter)
	- [Chat template and tokenizer sensibility](#chat-template-and-tokenizer-sensibility)
- [20. Exact implementation mapping](#20-exact-implementation-mapping)
	- [Layer 1 — HTTP/type contract](#layer-1--httptype-contract)
	- [Layer 2 — question compiler](#layer-2--question-compiler)
	- [Layer 3 — verbalizer validation](#layer-3--verbalizer-validation)
	- [Layer 4 — prefill-only inference](#layer-4--prefill-only-inference)
	- [Layer 5 — deterministic probability reduction](#layer-5--deterministic-probability-reduction)
- [21. Generic implementation pseudocode](#21-generic-implementation-pseudocode)
- [22. Why this is faster than text generation](#22-why-this-is-faster-than-text-generation)
- [23. Multiple questions: parallelism is not “one shared forward pass”](#23-multiple-questions-parallelism-is-not-one-shared-forward-pass)
- [24. Model-family portability](#24-model-family-portability)
	- [Causal decoder-only LM](#causal-decoder-only-lm)
	- [Encoder-decoder LM](#encoder-decoder-lm)
	- [Masked language model](#masked-language-model)
	- [Embedding-only model](#embedding-only-model)
- [25. Multimodal models](#25-multimodal-models)
- [26. Correctness invariants](#26-correctness-invariants)
	- [I1 — semantic mapping](#i1--semantic-mapping)
	- [I2 — tokenizer correctness](#i2--tokenizer-correctness)
	- [I3 — native-logit correctness](#i3--native-logit-correctness)
	- [I4 — normalization](#i4--normalization)
	- [I5 — no sampled generation](#i5--no-sampled-generation)
	- [I6 — generation-parameter independence](#i6--generation-parameter-independence)
	- [I7 — cache transparency](#i7--cache-transparency)
	- [I8 — isolation](#i8--isolation)
- [27. Verification strategy](#27-verification-strategy)
	- [27.1 Native one-token oracle](#271-native-one-token-oracle)
	- [27.2 Multi-character oracle](#272-multi-character-oracle)
	- [27.3 Tokenizer adversarial cases](#273-tokenizer-adversarial-cases)
	- [27.4 Sampling null test](#274-sampling-null-test)
	- [27.5 Candidate permutation tests](#275-candidate-permutation-tests)
	- [27.6 Cache equivalence](#276-cache-equivalence)
	- [27.7 Repetition/concurrency](#277-repetitionconcurrency)
	- [27.8 Calibration](#278-calibration)
- [28. Common conceptual errors](#28-common-conceptual-errors)
	- [“This is greedy decoding.”](#this-is-greedy-decoding)
	- [“Temperature 0 is equivalent.”](#temperature-0-is-equivalent)
	- [“0.9 probability means 90% real-world correctness.”](#09-probability-means-90-real-world-correctness)
	- [“No training means all backbones work equally well.”](#no-training-means-all-backbones-work-equally-well)
	- [“All questions use one forward pass.”](#all-questions-use-one-forward-pass)
	- [“The neural architecture changed.”](#the-neural-architecture-changed)
- [29. Recommended implementation architecture](#29-recommended-implementation-architecture)
- [30. Minimal backend API required](#30-minimal-backend-api-required)
- [31. Why the method is useful](#31-why-the-method-is-useful)
- [32. What this method does not prove](#32-what-this-method-does-not-prove)
- [33. Reference equations](#33-reference-equations)
	- [LM head](#lm-head)
	- [Native next-token probability](#native-next-token-probability)
	- [Restricted candidate softmax](#restricted-candidate-softmax)
	- [Stable softmax](#stable-softmax)
	- [Multi-symbol path](#multi-symbol-path)
	- [Candidate normalization](#candidate-normalization)
	- [Choice](#choice)
	- [Score](#score)
	- [Noul](#noul)
	- [Current local confidence heuristic](#current-local-confidence-heuristic)
	- [Optional post-hoc temperature scaling](#optional-post-hoc-temperature-scaling)
- [34. Implementation checklist](#34-implementation-checklist)
- [35. References and further reading](#35-references-and-further-reading)
	- [Implementation sources](#implementation-sources)
	- [Open method](#open-method)
	- [TypeSafe / Jev public semantics](#typesafe--jev-public-semantics)
	- [Mathematical background](#mathematical-background)
	- [Papers](#papers)
- [Citation](#citation)
---- 

## 1. Provenance

The reader should be able to follow the code. Therefore, the repository lineage matters as  the typed-decision behavior implementation at hand is a server/runtime modification to a fork of llama.cpp.

Provenance as of 2026-09-22:

* [`kyr0/Bonsai-Llama-Jev` ](https://github.com/kyr0/Bonsai-Llama-Jev)was forked from `PrismML-Eng/llama.cpp`.
* Its merge base immediately before the fork-local work is commit `3ae4f51087d8d9292eda16ee00cec54e798ea576`.
* The typed-decision implementation first appears in fork-local commit:
  * `8b1bb68f41a2a78e1e9ca5bd6155694e6a74ed7f` — `works`
* The next (first) fork-local commit:
  * `9203183e6c54fda23872f230e33c1985b713c10c` — server/runtime hardening, generation-cap handling, build/start/e2e work.

The important code archaeology is:

```text
PrismML llama.cpp
      |
      | inherited model/runtime implementation
      v
3ae4f510...
      |
      | fork-local typed-decision implementation
      v
8b1bb68...
      |
      | runtime/e2e hardening
      v
9203183...
```

The core files introduced / changed for typed decisions are:

```text
tools/server/SYSTEMONE.md
tools/server/server-context.cpp
tools/server/server-context.h
tools/server/server-task.h
tools/server/server.cpp
tools/server/tests/unit/test_chat_completion.py
```

The decisive implementation is in `server-context.cpp`: a new `SERVER_TASK_TYPE_SYSTEMONE` runs the normal model prompt forward pass, extracts selected logits at `SLOT_STATE_DONE_PROMPT`, sends those logits back to the HTTP-side decision logic, releases the inference slot, and returns **before normal token generation starts**.

---- 

## 2. Terminology and abbreviations

This method crosses language-model, probability, and inference-runtime terminology. The terms below are used precisely throughout this document.

| Term                           | Meaning here                                                                                                                                                                                                                   |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **LM**                         | Language model.                                                                                                                                                                                                                |
| **LLM**                        | Large language model. Size is irrelevant to the method; the same readout principle applies to smaller causal LMs.                                                                                                              |
| **Causal / autoregressive LM** | A model trained/inferred so token position $t$ predicts a distribution for the next token from earlier tokens.                                                                                                                 |
| **Token**                      | Integer symbol consumed/emitted by the model. A token is **not** necessarily one character or one word.                                                                                                                        |
| **Tokenizer**                  | Deterministic mapping between text and token IDs. Its context-sensitive segmentation is why answer-label validation is required.                                                                                               |
| **Vocabulary $V$**             | Finite set of token IDs the LM can predict.                                                                                                                                                                                    |
| **Hidden state $h_T$**         | Final internal vector at prompt position $T$, before the LM output head.                                                                                                                                                       |
| **LM head**                    | Existing output projection that maps a hidden state to one score per vocabulary token.                                                                                                                                         |
| **Logit**                      | Pre-softmax model score. In neural-network usage this usually means an unnormalized score; it should not be confused with the strict binary-statistics definition of log-odds.                                                 |
| **Softmax**                    | Function converting real-valued scores into positive normalized weights summing to 1.                                                                                                                                          |
| **Restricted softmax**         | Softmax computed only over the answer-token subset rather than over the whole vocabulary.                                                                                                                                      |
| **Verbalizer**                 | Mapping from a semantic class such as `technical` to one or more model tokens such as `B`.                                                                                                                                     |
| **Prefill**                    | Evaluation of the known input prompt. It produces model state/KV cache and logits at the prompt boundary before any generated continuation token.                                                                              |
| **Decode**                     | Repeated continuation phase in which new output tokens are selected/appended and the model advances from them.                                                                                                                 |
| **Sampler**                    | Generation component that transforms/selects from logits using operations such as temperature, top-$k$, top-$p$, penalties, random sampling, or greedy selection.                                                              |
| **KV cache**                   | Cached attention **K**ey/**V**alue tensors for already-evaluated prefix tokens, allowing suffix continuations to avoid recomputing the full prefix.                                                                            |
| **Argmax**                     | Index of the largest value. Used here to select the highest-probability semantic candidate after probability computation.                                                                                                      |
| **System One**                 | [TypeSafe API surface](http://api.typesafe.ai/openapi.json) for asking typed questions over supplied state. “System One compatible” here refers to the request/response contract, not a claim about proprietary Jev internals. |
| **Choice**                     | Unordered finite-class primitive: return one selected semantic option and a distribution across options.                                                                                                                       |
| **Score**                      | Ordered finite-level primitive: return the probability-weighted expected level plus the distribution.                                                                                                                          |
| **Noul**                       | TypeSafe yes/no primitive: return the probability of “yes”.                                                                                                                                                                    |
| **Calibration**                | Empirical property that predicted probabilities correspond to observed frequencies/correctness rates on a defined population.                                                                                                  |
| **NLL**                        | Negative log-likelihood, a proper probabilistic scoring rule used when evaluating predicted class probabilities.                                                                                                               |
| **Brier score**                | Squared-error proper scoring rule for probabilistic predictions.                                                                                                                                                               |
| **ECE**                        | Expected Calibration Error: a binned summary of the gap between predicted probability and observed frequency; its value depends on the binning scheme.                                                                         |
| **GGUF**                       | Model/container format used by llama.cpp-family runtimes. It is not part of the decision mathematics.                                                                                                                          |

Two distinctions are especially important:

1. **prefill is not decoding**: the model can compute next-token logits at the end of a prompt without emitting any token;
2. **deterministic readout is not calibration**: a mathematically exact transformation of model logits can still be statistically miscalibrated against real outcomes.

---- 

## 3. What is actually being transformed?

An ordinary causal LM is already a next-token classifier over its vocabulary.

Given a tokenized prefix

$$x_{1:T}=(x_1,x_2,\ldots,x_T),$$

the model computes a final hidden representation $h_T$. Its language-model output head maps that hidden vector into one real-valued score for every vocabulary token:

$$\mathbf z=Wh_T+\mathbf b,
\qquad
\mathbf z\in\mathbb R^{|V|}.$$

Where:

* $V$ = tokenizer vocabulary;
* $|V|$ = vocabulary size;
* $T$ = prompt length in tokens;
* $h_T$ = hidden state at the final prompt position;
* $W,\mathbf b$ = existing LM output projection;
* $\mathbf z$ = vector of logits/pre-softmax scores;
* $z_v$ = score assigned to vocabulary token $v$.

The ordinary next-token distribution is:

$$P_\theta(v\mid x_{1:T})
=
\frac{\exp(z_v)}
{\sum_{u\in V}\exp(z_u)}.$$

Transformer decoders conventionally end in an output projection and softmax over possible symbols.

### LM head and next-token distribution

$$\mathbf z=Wh_T+\mathbf b$$

$$P(v\mid x_{1:T})
=
\frac{\exp(z_v)}
{\sum_{u\in V}\exp(z_u)}$$

The typed-decision engine exploits a consequence that is easy to miss:

> The LM already computed scores for *every possible next token*. If we encode each semantic answer as a known answer token, classification is already present in the final logits. We do not need the model to generate text explaining its choice.

This is related to the **verbalizer** idea in prompt-based classification: semantic classes are mapped to token-level labels that the LM can score. PET (*Pattern-Exploiting Training*, Schick & Schütze, EACL 2021) is a well-known example of this general class-to-token interface.

---- 

## 4. The system-level transformation

Let:

* $s$ = application state/evidence;
* $q$ = a natural-language question/criterion;
* $C=\{c_1,\ldots,c_N\}$ = semantic answer candidates;
* $\Phi(s,q,C)$ = deterministic prompt compiler;
* $g(c_i)=\ell_i$ = verbalizer mapping candidate $c_i$ to answer label $\ell_i$;
* $f_\theta$ = unchanged causal language model;
* $R$ = probability readout;
* $A$ = typed reducer (`choice`, `score`, or `noul`).

Then:

$$D_\theta(s,q,C)
=
A\!\left(
R\!\left(
f_\theta(\Phi(s,q,C)),
g(C)
\right)
\right).$$

The model parameters $\theta$ are unchanged.

Thus:

$$\boxed{
\text{typed decision engine}
=
\text{ordinary LM}
+
\text{prompt compiler}
+
\text{logit readout}
+
\text{deterministic probability math}
}$$

No classifier head must be trained. No adapter must be attached. No sampler is necessary.

Saying “we implemented a different neural forward pass” is therefore slightly imprecise. The **neural forward graph remains the same**. What changes is the **server execution path**:

1. compile request into classification prompt;
2. evaluate prompt normally;
3. expose logits at the prompt boundary;
4. copy only selected logits;
5. exit before decoding;
6. produce the typed answer with deterministic CPU-side math.

---- 

## 5. Generation vs. typed decision readout

### 5.1 Ordinary autoregressive generation

A normal generation engine conceptually performs:

```text
prompt
  ↓
prefill
  ↓
logits z₀
  ↓
temperature / top-k / top-p / penalties / ...
  ↓
sample or argmax y₁
  ↓
append y₁
  ↓
decode forward
  ↓
logits z₁
  ↓
select y₂
  ↓
...
```

Generated text follows the autoregressive factorization:

$$P(y_{1:K}\mid x)
=
\prod_{t=1}^{K}
P(y_t\mid x,y_{<t}).$$

A generation engine therefore contains a serial **decode loop**.

### 5.2 Typed decision mode

For a one-token label set:

```text
state + question + candidates
  ↓
deterministic prompt
  ↓
prefill
  ↓
final-position logits z
  ↓
gather z[A], z[B], z[C], ...
  ↓
restricted softmax
  ↓
typed reduction
  ↓
JSON response
```

There is no generated token between the model and the typed answer.

In the current implementation:

```text
SERVER_TASK_TYPE_SYSTEMONE
    ↓
normal prompt evaluation
    ↓
SLOT_STATE_DONE_PROMPT
    ↓
llama_get_logits_ith(...)
    ↓
copy logits for task.systemone_tokens
    ↓
queue result
    ↓
slot.release()
    ↓
return
```

The normal sampler chain is never entered.

Consequences:

* no random draw;
* no `top-k`;
* no `top-p`;
* no repetition/frequency/presence penalty;
* no generated answer JSON to parse;
* no grammar-constrained decoding;
* no risk that the model emits `"A"` and then an explanation;
* `usage.output_tokens == 0` for this local method.

The only `argmax` is later applied to the semantic candidate probability vector. That is classification, not greedy text decoding.

### “No sampling” does not imply bitwise determinism

Removing sampling removes an explicit stochastic operation. It does not guarantee bit-identical outputs across:

* CPU/GPU backends;
* quantization formats;
* batching;
* kernel implementations;
* thread counts;
* floating-point reduction order.

Cross-backend equivalence still requires numerical tolerances.

---- 

## 6. Turning semantic answers into token labels

Suppose the application asks:

```json
{
  "state": "The Stripe integration has failed for three days and sales are being lost.",
  "questions": {
    "department": {
      "type": "choice",
      "instructions": "Which team should handle this?",
      "criteria": {
        "billing": "Payments and subscriptions",
        "technical": "Bugs and integrations",
        "sales": "Pricing and account questions"
      }
    }
  }
}
```

The engine does not ask the model to generate `"technical"`.

Instead:

```text
A -> billing
B -> technical
C -> sales
```

The semantic names/descriptions enter the prompt; the output boundary uses a tiny label alphabet.

```text
semantic class       verbalizer
------------------   ----------
billing              A
technical            B
sales                C
```

The current repository uses:

```text
ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789
```

giving 62 single-character labels.

---- 

## 7. The critical tokenizer invariant

The direct readout is exact only if an answer character really is one token **at the exact prompt boundary**.

Let:

* $\tau(P)$ = tokenization of rendered prompt $P$;
* $c$ = answer character;
* $t_c$ = its token ID.

Require:

$$\tau(P\Vert c)
=
\tau(P)\Vert[t_c].$$

That means:

1. appending `A` adds exactly one token;
2. the existing prompt tokens do not change;
3. the token decodes back to exactly `A`;
4. answer characters map to distinct token IDs.

The repository explicitly verifies these properties.

Conceptually:

```cpp
prefix   = tokenize(prompt);
extended = tokenize(prompt + "A");

require(extended.size() == prefix.size() + 1);
require(extended[0:prefix.size()] == prefix);
require(piece(extended.back()) == "A");
require(token_id_for_A_is_unique);
```

This matters because BPE/unigram tokenizers can merge punctuation, whitespace, and following text. It is possible that:

```text
tokenize("answer:")
```

is not a prefix of:

```text
tokenize("answer:A")
```

The current engine therefore fails with HTTP 422 rather than silently scoring the wrong token.

Hence “any LM” should be qualified:

> The current implementation supports a **causal next-token LM whose tokenizer/chat-template combination provides usable singleton answer tokens at the output boundary**.

A generalized prefix-trie implementation can remove that restriction.

---- 

## 8. Restricted softmax: the central identity

Assume $N$ candidates use one-token verbalizers:

$$A=\{t_1,\ldots,t_N\}.$$

The LM returns full-vocabulary logits $\mathbf z$. We copy only:

$$z_{t_1},z_{t_2},\ldots,z_{t_N}.$$

Compute:

$$q_i
=
\frac{\exp(z_{t_i})}
{\sum_{j=1}^{N}\exp(z_{t_j})}.$$

This is a **restricted softmax** over answer tokens. Softmax converts arbitrary real scores into positive normalized weights summing to one.

### Why it is exactly the native LM distribution conditioned on allowed labels

Full-vocabulary probability:

$$P(t_i\mid P)
=
\frac{\exp(z_{t_i})}
{\sum_{u\in V}\exp(z_u)}.$$

Condition on the next token being one of the allowed candidate labels $A$:

$$P(t_i\mid P,t\in A)
=
\frac{P(t_i\mid P)}
{\sum_{j=1}^{N}P(t_j\mid P)}.$$

Substitute full softmax:

$$P(t_i\mid P,t\in A)
=
\frac{
\frac{\exp(z_{t_i})}{Z_V}
}{
\sum_j
\frac{\exp(z_{t_j})}{Z_V}
},$$

where:

$$Z_V=\sum_{u\in V}\exp(z_u).$$

The vocabulary denominator cancels:

$$P(t_i\mid P,t\in A)
=
\frac{\exp(z_{t_i})}
{\sum_j\exp(z_{t_j})}
=
q_i.$$

Therefore:

$$\boxed{
\text{restricted softmax over selected logits}
=
\text{native next-token distribution conditioned on the supplied labels}
}$$

### What the existing unit test proves

`test_systemone_matches_native_probabilities`:

1. builds the same rendered prompt;
2. obtains native `A`/`B` token IDs;
3. calls the ordinary completion path for native full-vocabulary next-token probabilities;
4. extracts those token probabilities;
5. renormalizes over `A` and `B`;
6. compares against `/v1/systemone`.

Agreement is checked to approximately $10^{-5}$.

Thus, for single-token candidates, System One is exposing the backbone's existing probability geometry under a restricted label space.

---- 

## 9. Numerical stability: subtract the maximum logit

Naive exponentiation can overflow.

Use:

$$m=\max_jz_j$$

and:

$$q_i
=
\frac{\exp(z_i-m)}
{\sum_j\exp(z_j-m)}.$$

The result is unchanged because the common factor $\exp(-m)$ cancels.

This is the standard max-subtraction/log-sum-exp stabilization technique.

The current implementation performs probability arithmetic in `double`, although copied logits arrive as `float`.

---- 

## 10. Worked one-token example

Suppose:

```text
A / billing:    2.1
B / technical:  0.9
C / sales:     -0.1
```

Subtract $m=2.1$:

$$[2.1,0.9,-0.1]-2.1
=
[0,-1.2,-2.2].$$

Exponentiate:

$$[e^0,e^{-1.2},e^{-2.2}]
\approx
[1,0.3010,0.1108].$$

Normalize:

$$Z=1+0.3010+0.1108=1.4118.$$

Therefore:

$$\mathbf p
\approx
[0.7082,0.2133,0.0785].$$

The `choice` is candidate `A`.

No answer token was generated.

---- 

### 11. Factorized multi-character labels

For  $N>62$, labels use multiple characters, because the set of single-character labels is exceeded (see 6.).

Let the label width be $D$, with radix sizes:

$$r_0,r_1,\ldots,r_{D-1}.$$

Capacity:

$$C=\prod_{d=0}^{D-1}r_d.$$

Require:

$$C\ge N.$$

The implementation searches for radix sizes that minimize capacity and then prefix-readout cost.

For 67 candidates:

```text
radices  = 2 × 34
capacity = 68
```

### Why additional model evaluations are necessary

For label `BA`, the second character must be scored conditional on `B`.

By the probability chain rule:

$$P(BA\mid P)
=
P(B\mid P)P(A\mid P,B).$$

More generally:

$$P(\ell_0\ell_1\cdots\ell_{D-1}\mid P)
=
\prod_{d=0}^{D-1}
P(\ell_d\mid P,\ell_{<d}).$$

This is the standard probability chain rule.

The current engine uses a **restricted categorical probability at every branch**:

$$q_d(c\mid\pi)
=
\frac{
\exp(z_c(P,\pi))
}{
\sum_{a\in A_d}\exp(z_a(P,\pi))
}.$$

For candidate $i$:

$$w_i
=
\prod_{d=0}^{D-1}
q_d
\left(
\ell_i[d]
\mid
\ell_i[:d]
\right).$$

Finally:

$$p_i
=
\frac{w_i}
{\sum_{j=1}^{N}w_j}.$$

### Important semantic nuance

For multi-character labels this is best understood as a **forced categorical decision tree**.

It is not exactly the raw unrestricted language-model probability of the complete label string, because every branch is renormalized over valid answer symbols:

$$q_d(c\mid\pi)
=
P_\theta(c\mid P,\pi,c\in A_d).$$

The engine asks:

> Among valid answer symbols at this branch, how does the model distribute support?

That is the desired quantity for a typed classifier.

---- 

## 12. Readout-count complexity

For radices $r_0,\ldots,r_{D-1}$:

$$R
=
\sum_{d=0}^{D-1}
\prod_{k=0}^{d-1}r_k,$$

with empty product $=1$.

Examples from the implementation:

| Candidates | Radices     | Capacity | Readouts |
| ---------: | ----------: | -------: | -------: |
| 27         | 27          | 27       | 1        |
| 53         | 53          | 53       | 1        |
| 62         | 62          | 62       | 1        |
| 63         | 3 × 21      | 63       | 4        |
| 67         | 2 × 34      | 68       | 3        |
| 100        | 2 × 50      | 100      | 3        |
| 677        | 17 × 40     | 680      | 18       |
| 3844       | 62 × 62     | 3844     | 63       |
| 3845       | 2 × 37 × 52 | 3848     | 77       |

Therefore “no decoding” does **not** mean “one neural evaluation for arbitrary candidate counts.”

For $N\le62$ (single-character label case), one final-position readout is enough per question.

For wider labels, deterministic prefix branches require additional suffix evaluations. They are still not sampled/generated outputs.

---- 

## 13. KV-cache reuse makes prefix branches cheap

The KV cache stores previously computed attention keys and values.

Without reuse:

```text
prompt + A
prompt + B
prompt + C
```

would each repeat the entire prompt computation.

With reuse:

```text
prefill(prompt) -> KV(prompt)

branch A -> suffix only
branch B -> suffix only
branch C -> suffix only
```

The current server sets:

```cpp
task.params.cache_prompt = depth > 0;
```

for deeper label-prefix readouts.

Cache reuse changes performance, not probability semantics. Cache eviction or slot scheduling can still force reevaluation.

---- 

## 14. Generalizing to arbitrary token verbalizers

The alphanumeric scheme is practical, but a fully portable engine should support candidate verbalizers of arbitrary token length.

Construct a prefix trie:

```text
                  root
                /      \
             token 91   token 42
             /    \         \
          17      88         5
```

At every node:

1. evaluate/read logits;
2. gather token IDs corresponding to outgoing edges;
3. restricted-softmax those edges;
4. multiply the parent path weight;
5. continue through cached suffix branches;
6. terminal-node weight becomes candidate weight;
7. normalize terminal candidates.

Suggested abstraction:

```cpp
struct DecisionCandidate {
    std::string semantic_id;
    std::vector<llama_token> verbalizer;
};

struct DecisionTrieNode {
    std::map<llama_token, NodeId> edges;
    std::optional<size_t> candidate;
};
```

The runtime then needs only:

```cpp
SelectedLogits score_next(
    PrefixState prefix,
    span<const llama_token> allowed_tokens);
```

---- 

## 15. Typed reducers

After obtaining:

$$\mathbf p=(p_0,\ldots,p_{N-1}),
\qquad
\sum_i p_i=1,$$

the API primitives are deterministic reductions.

### 15.1 Choice

$$i^*
=
\operatorname*{arg\,max}_i p_i.$$

TypeSafe's public Choice contract similarly exposes the selected option, a probability per supplied option, and confidence.

### 15.2 Score

For ordered levels $0,\ldots,N-1$:

$$\operatorname{score}
=
\mathbb E[L]
=
\sum_{i=0}^{N-1}i\,p_i.$$

This is ordinary statistical expected value.

TypeSafe documents exactly this probability-weighted-level interpretation; for example, probabilities $0,0.57,0.43$ over levels $0,1,2$ yield score $1.43$.

### 15.3 Noul

TypeSafe defines Noul as a yes/no question returning the probability of “yes”.

Internally:

```text
yes
no
```

with:

$$p_{\text{yes}}+p_{\text{no}}=1.$$

The current implementation computes:

$$\operatorname{noul}
=
\frac{
p_{\text{yes}}+(1-p_{\text{no}})
}{2}.$$

Since:

$$1-p_{\text{no}}=p_{\text{yes}},$$

this simplifies to:

$$\boxed{
\operatorname{noul}=p_{\text{yes}}
}$$

---- 

## 16. The `confidence` field is a local heuristic

Lacking any better known option, we currently compute:

$$C
=
p_{i^*}
\prod_{i\ne i^*}(1-p_i).$$

This is a deterministic concentration heuristic.

It is **not** a theorem that:

$$C=P(\text{decision is correct}).$$

For binary winner probability $p$:

$$C=p^2.$$

Thus:

$$p=0.8\Rightarrow C=0.64.$$

For the previous three-class example:

$$\mathbf p\approx[0.7082,0.2133,0.0785],$$

so:

$$C
\approx
0.7082(1-0.2133)(1-0.0785)
\approx0.5134.$$

TypeSafe's public docs describe `confidence` as derived from how spread/peaked the probability distribution is; with no further information about Jev’s implementation, we cannot establish this local formula as Jev's production formula.

Downstream systems should distinguish:

1. candidate probability;
2. distribution-concentration confidence;
3. calibrated probability of correctness.

---- 

## 17. Conditional option probabilities are not automatically calibrated probabilities

The direct readout is exact relative to the model and prompt:

$$p_i
=
P_\theta(
\text{label }i
\mid
\text{prompt},
\text{allowed labels}
).$$

That does not imply:

$$p_i
=
P(
\text{semantic class }i\text{ is objectively correct}
\mid
\text{real task}
).$$

The readout inherits:

* model errors;
* domain shift;
* prompt framing effects;
* verbalizer preferences;
* candidate-order effects;
* incomplete candidate sets;
* overlapping criteria;
* quantization/backend effects.

Thus, Softmax over allowed answer tokens is conditional on supplied alternatives and is not automatically operationally calibrated confidence.

Zhao et al. show that language-model classification can be highly sensitive to prompt format, example ordering, and answer biases, motivating contextual calibration. This should be considered as well.  
  
The safest interpretation is:

> Given this prompt and these alternatives, how does this backbone distribute its answer preference among them?

If the candidate set is incomplete, the probabilities still sum to one.

Use `other`, `none`, `insufficient evidence`, or an abstention class when the task is genuinely open-set.

---- 

## 18. Calibration can be added without changing model weights

Suppose the engine produces scores $s_i$. A post-hoc temperature parameter $T>0$ can transform them:

$$p_i(T)
=
\frac{\exp(s_i/T)}
{\sum_j\exp(s_j/T)}.$$

* $T=1$: unchanged.
* $T>1$: flatter.
* $0<T<1$: sharper.

Fit $T$ on a held-out calibration set by minimizing NLL.

Guo et al. found temperature scaling to be a simple and often effective post-hoc calibration method for neural classifiers.

### Sampling temperature vs. calibration temperature

These may use mathematically similar divisions by $T$, but serve different purposes.

**Sampling temperature**

```text
logits -> temperature -> token-selection sampler
```

belongs to generation.

**Calibration temperature**

```text
decision scores -> fitted T -> deterministic probabilities
```

is a deterministic probability mapping.

Therefore a calibrated decision engine can still correctly claim **no sampling**.

Do not fit calibration parameters on the final test set.

Use:

```text
training/model data
       ↓
calibration/validation split
       ↓
untouched test split
```

---- 

## 19. Prompt construction is part of the effective model

Operationally the decision function is not only:

$$f_\theta,$$

but:

$$f_\theta\circ\Phi,$$

where $\Phi$ includes:

* prompt structure;
* candidate ordering;
* descriptions;
* chat template;
* tokenizer;
* answer boundary.

The current implementation builds a structured payload conceptually resembling:

```json
{
  "evidence": "...",
  "criterion": "...",
  "options": [
    {
      "letter": "A",
      "name": "billing",
      "description": "Payments and subscriptions"
    }
  ]
}
```

and applies the model's normal chat template with thinking disabled.

### Candidate order can matter

Mapping a semantic candidate to `A` instead of `B` changes the rendered prompt.

Thus candidate permutations should be treated as a semantic-stability test.

### Chat template and tokenizer sensibility

Control tokens, whitespace and the chat template itself remain important. 

They determine:

* control token definition;
* whitespace definition;
* role separators;
* the answer boundary;
* tokenization of verbalizers.

Tokenizer validation must therefore operate on the **fully rendered prompt**.

---- 

## 20. Exact implementation mapping

In Bonsai-Llama-Jev, the System One API is added alongside the existing OpenAI API and llama.cpp native HTTP APIs:

### Layer 1 — HTTP/type contract

`server.cpp` registers:

```text
POST /v1/systemone
```

with 422-style request validation.

Question types:

```text
choice
score
noul
```

### Layer 2 — question compiler

`systemone_question` in `server-context.cpp`:

* validates the schema;
* constructs semantic candidates;
* selects label widths/radices;
* maps indices to labels;
* builds chat messages;
* reduces probability vectors into responses.

### Layer 3 — verbalizer validation

Each used answer character must:

* add exactly one token;
* preserve the existing prompt tokenization;
* decode to the intended character;
* have a distinct token ID.

### Layer 4 — prefill-only inference

`server-task.h` introduces:

```cpp
SERVER_TASK_TYPE_SYSTEMONE
```

plus:

```cpp
llama_tokens systemone_tokens;
```

and `need_logits()` returns true for the task.

At prompt completion, the key path is effectively:

```cpp
const float * logits =
    llama_get_logits_ith(ctx_tgt, slot.i_batch - off);

for (llama_token token : slot.task->systemone_tokens) {
    result->logits.push_back(logits[token]);
}

queue_results.send(...);
slot.release();
return;
```

That `return` is the decisive boundary.

### Layer 5 — deterministic probability reduction

The HTTP-side path:

1. waits for readouts;
2. stable-softmaxes selected logits;
3. multiplies conditional branch probabilities where needed;
4. renormalizes listed candidates;
5. applies the typed reducer;
6. returns JSON with `output_tokens = 0`.

---- 

## 21. Generic implementation pseudocode

A portable engine can expose one primitive:

```text
score_allowed_next_tokens(prefix, allowed_token_ids) -> logits[]
```

Then:

```text
function decide(state, questions):
    answers = {}

    for question in questions:
        candidates = compile_candidates(question)
        prompt = render_prompt(state, question, candidates)
        verbalizers = compile_and_validate_verbalizers(prompt, candidates)

        trie = build_prefix_trie(verbalizers)
        path_weight = array(candidate_count, 0.0)

        queue = [(root, tokenize(prompt), 1.0)]

        while queue not empty:
            node, prefix_tokens, node_weight = queue.pop()

            outgoing = node.outgoing_token_ids

            logits =
                prefill_or_cached_suffix_forward(
                    prefix_tokens,
                    outgoing
                )

            local_p = stable_softmax(logits)

            for each edge(token -> child):
                child_weight =
                    node_weight * local_p[token]

                if child is terminal:
                    path_weight[child.candidate] += child_weight
                else:
                    queue.push(
                        child,
                        prefix_tokens + [token],
                        child_weight
                    )

        p = normalize(path_weight)

        answers[question.id] =
            typed_reduce(question.type, p)

    return {
        answers,
        usage: {
            input_tokens: logical_input_usage,
            output_tokens: 0
        }
    }
```

---- 

## 22. Why this is faster than text generation

Normal generation of $K$ output tokens costs approximately:

$$t_{\text{generation}}
\approx
t_{\text{prefill}}
+
\sum_{k=1}^{K}t_{\text{decode},k}.$$

One-token typed decision:

$$t_{\text{decision}}
\approx
t_{\text{prefill}}
+
t_{\text{gather}}
+
t_{\text{softmax}}.$$

`gather + softmax + reducer` is tiny relative to a large Transformer forward.

The system also avoids:

* serial decode synchronization;
* sampling;
* detokenization;
* generated JSON repair;
* retries caused by malformed model output.

For independent questions, tasks can also be batched by the server.

---- 

## 23. Multiple questions: parallelism is not “one shared forward pass”

A request may contain many questions.

The current server can schedule/batch their work together, but each question has its own criterion/options and therefore its own compiled prompt.

Thus:

```text
parallel/batched inference
```

does not imply:

```text
one shared hidden state answers every question
```

For one-character labels:

* one root readout per question;
* zero generation.

For multi-character labels:

* root readout;
* additional required prefix branches.

---- 

## 24. Model-family portability

### Causal decoder-only LM

Use:

```text
final prompt position
  ↓
next-token logits
```

This is the current implementation.

### Encoder-decoder LM

Use:

```text
encoder(state/question/options)
  +
decoder start state
  ↓
decoder token logits
```

The restricted-softmax logic still applies.

### Masked language model

For a BERT-like model:

```text
prompt containing [MASK]
  ↓
hidden state at [MASK]
  ↓
vocabulary logits
  ↓
restricted verbalizer softmax
```

### Embedding-only model

An embedding model has no token-prediction head, so this exact method does not apply. It requires a classifier, reranker, or similarity rule.

Thus “any LM” more precisely means:

> any model exposing an appropriate token-prediction distribution through its inference runtime.

---- 

## 25. Multimodal models

For multimodal causal models:

```text
image/audio/text state
      ↓
multimodal prefill
      ↓
final LM logits
      ↓
same selected-token readout
      ↓
same typed math
```

The current repo's System One media extension uses the existing multimodal parser/projector.

A text-only model remains text-only.

---- 

## 26. Correctness invariants

### I1 — semantic mapping

Every semantic candidate has exactly one verbalizer path.

### I2 — tokenizer correctness

Every verbalizer is exactly the token path evaluated at the real prompt boundary.

### I3 — native-logit correctness

For every selected token $t$, decision mode returns the model's native $z_t$.

### I4 — normalization

$$p_i\ge0,
\qquad
\sum_i p_i=1.$$

### I5 — no sampled generation

Decision mode emits no sampled model token.

### I6 — generation-parameter independence

Changing:

```text
top_k
top_p
min_p
sampling temperature
penalties
```

must not alter decision probabilities.

### I7 — cache transparency

Cache reuse may change latency but not semantic output beyond numerical tolerance.

### I8 — isolation

Typed-decision support must not alter ordinary chat/completion behavior.

---- 

## 27. Verification strategy

### 27.1 Native one-token oracle

Verify:

$$p_i^{\text{decision}}
\approx
\frac{
p_i^{\text{native LM}}
}{
\sum_{j\in A}p_j^{\text{native LM}}
}.$$

Test across:

* many prompts;
* several candidate counts;
* quantizations;
* CPU/GPU backends.

### 27.2 Multi-character oracle

For every prefix:

1. native forward at exact prefix;
2. gather same allowed logits;
3. compare local restricted softmax;
4. multiply path probabilities independently;
5. compare final candidate distribution.

### 27.3 Tokenizer adversarial cases

Test:

* whitespace;
* punctuation boundaries;
* merged `" A"` tokens;
* non-Latin tokenizers;
* context-sensitive segmentations.

Fail rather than approximate.

### 27.4 Sampling null test

Vary all sampler controls.

Result should remain unchanged.

### 27.5 Candidate permutation tests

Permute option order, map outputs back to semantic IDs, then measure:

* argmax agreement;
* total variation distance;
* JS/KL divergence where meaningful.

### 27.6 Cache equivalence

Compare cache reuse on/off.

Expected:

```text
same probabilities
different compute cost
```

### 27.7 Repetition/concurrency

Stress:

* repeated identical requests;
* concurrent requests;
* slot pressure;
* different batch composition.

### 27.8 Calibration

On untouched labeled data report:

* NLL;
* Brier score;
* reliability diagram;
* ECE with exact binning;
* accuracy/F1 where relevant;
* risk/coverage if thresholds gate actions.

---- 

## 28. Common conceptual errors

### “This is greedy decoding.”

No.

Greedy decoding selects a token, appends it, and continues decoding.

Decision mode reads scores and returns structured data.

### “Temperature 0 is equivalent.”

No.

Temperature 0 is usually a generation-path convention.

This method bypasses the generation sampler.

### “0.9 probability means 90% real-world correctness.”

Not without calibration evidence.

It is a restricted model probability under a particular prompt/candidate set.

### “No training means all backbones work equally well.”

No.

Structural compatibility and semantic decision quality are separate.

### “All questions use one forward pass.”

Not necessarily.

They are separately compiled readouts that can be batched.

### “The neural architecture changed.”

No.

The model weights/graph stay intact. The runtime exposes a different readout and termination point.

---- 

## 29. Recommended implementation architecture

```text
┌────────────────────────────────────────────┐
│ 1. Typed API / validation                  │
│    state, model, questions                 │
└──────────────────┬─────────────────────────┘
                   v
┌────────────────────────────────────────────┐
│ 2. Decision compiler                       │
│    semantics -> prompt + verbalizers       │
│    tokenizer validation                    │
└──────────────────┬─────────────────────────┘
                   v
┌────────────────────────────────────────────┐
│ 3. Inference primitive                     │
│    prefill / cached suffix                 │
│    selected native logits                  │
│    NO sampler / NO decode loop             │
└──────────────────┬─────────────────────────┘
                   v
┌────────────────────────────────────────────┐
│ 4. Probability + reducer                   │
│    stable softmax / chain rule             │
│    choice | score | noul                   │
│    optional calibration                    │
└────────────────────────────────────────────┘
```
---- 

## 30. Minimal backend API required

The backend does not need to know the meaning of `choice`, `score`, or `noul`.

It only needs:

```cpp
struct LogitReadoutRequest {
    TokenSequence prefix;
    std::vector<TokenId> selected_tokens;
    PrefixCachePolicy cache_policy;
};

struct LogitReadoutResult {
    std::vector<float> logits;
    size_t logical_input_tokens;
};
```

Semantics:

```text
evaluate prefix
do not sample
do not generate
return z[token_id] for requested token IDs
```

In llama.cpp, the underlying capability already exists through:

```cpp
llama_get_logits_ith(...)
```

The implementation task is exposing it at the correct server lifecycle boundary.

---- 

## 31. Why the method is useful

It transforms:

$$\text{unstructured state}
\longrightarrow
\text{typed probability distribution}.$$

Properties:

* **schema-safe by construction**;
* **generation-free**;
* **runtime-defined classes**;
* **probabilistic**;
* **backbone-agnostic within stated constraints**;
* **post-hoc calibratable**;
* **batchable**;
* **multimodal when the backbone is**.

The most accurate description is:

> **a discriminative readout layer over a generative language-model backbone**

rather than “prompting an LLM to output JSON.”

Energy consumption and time spent is reduced. Therefore, also cost is reduced.  
  
The method is useful for every non-open question format. If a question can be formulated or re-formulated as a closed question, the method applies.

---- 

## 32. What this method does not prove

It establishes:

* typed API plumbing;
* native logit extraction;
* mathematically defined candidate normalization;
* sampling-free execution;
* deterministic typed reduction;
* restricted-native-probability equivalence for singleton verbalizers.

It does not by itself establish:

* Jev architecture equivalence;
* Jev training equivalence;
* Jev calibration equivalence;
* domain accuracy;
* prompt-injection resistance;
* open-set correctness;
* safety for consequential autonomous actions.

Cloudflare currently describes Jev as a structured evaluation model that answers typed Noul/Choice/Score questions with calibrated answers, probabilities, and confidence. That is a product-level contract/claim, not a public architectural specification.

The local engine should therefore be described as **Jev-like / System-One-compatible**, not as a reproduction of undisclosed Jev internals.

---- 

## 33. Reference equations

### LM head

$$\mathbf z=Wh_T+\mathbf b$$

### Native next-token probability

$$P(v\mid x)
=
\frac{e^{z_v}}
{\sum_{u\in V}e^{z_u}}$$

### Restricted candidate softmax

$$p_i
=
\frac{e^{z_{t_i}}}
{\sum_j e^{z_{t_j}}}$$

### Stable softmax

$$m=\max_jz_{t_j}$$

$$p_i
=
\frac{e^{z_{t_i}-m}}
{\sum_j e^{z_{t_j}-m}}$$

### Multi-symbol path

$$w_i
=
\prod_dq_d(\ell_i[d]\mid\ell_i[:d])$$

### Candidate normalization

$$p_i
=
\frac{w_i}{\sum_jw_j}$$

### Choice

$$i^*=\arg\max_ip_i$$

### Score

$$\operatorname{score}
=
\sum_iip_i$$

### Noul

$$\operatorname{noul}=p_{\text{yes}}$$

### Current local confidence heuristic

$$C
=
p_{i^*}
\prod_{i\ne i^*}(1-p_i)$$

### Optional post-hoc temperature scaling

$$p_i(T)
=
\frac{e^{s_i/T}}
{\sum_je^{s_j/T}}$$

---- 

## 34. Implementation checklist

Should you plan to implement this method in any inference engine, the following tasks need to be done:
* [ ] Add typed-decision request schema.
* [ ] Define `choice`, `score`, `noul`.
* [ ] Compile each question into deterministic prompt + candidates.
* [ ] Assign candidate verbalizers.
* [ ] Validate verbalizers at the rendered tokenizer boundary.
* [ ] Add task type requesting logits.
* [ ] Run normal prompt prefill.
* [ ] Gather only requested vocabulary logits.
* [ ] Return before sampler/decode loop.
* [ ] Implement stable restricted softmax in `double`.
* [ ] Support cached prefix branches for multi-token labels.
* [ ] Renormalize listed semantic candidates.
* [ ] Implement typed reducers.
* [ ] Keep generation sampler parameters out of this path.
* [ ] Report zero generated output tokens.
* [ ] Reuse KV cache.
* [ ] Batch independent readouts where supported.
* [ ] Test against native full-vocabulary probabilities.
* [ ] Test cache on/off equivalence.
* [ ] Test tokenizer edge cases.
* [ ] Test candidate-order sensitivity separately.
* [ ] Evaluate semantic quality on labeled data.
* [ ] Fit calibration only on held-out calibration data.
* [ ] Evaluate calibration on untouched test data.

---- 

## 35. References and further reading

### Implementation sources

* `kyr0/Bonsai-Llama-Jev`
* typed-decision implementation: commit `8b1bb68f41a2a78e1e9ca5bd6155694e6a74ed7f`
* runtime/e2e hardening: commit `9203183e6c54fda23872f230e33c1985b713c10c`
* `tools/server/SYSTEMONE.md`
* `tools/server/server-context.cpp`
* `tools/server/server-task.h`
* `tools/server/tests/unit/test_chat_completion.py`

### Open method

* `bonsai/openjev`, `docs/METHOD.md` — generation-free direct final-position answer-token readout.

### TypeSafe / Jev public semantics

* TypeSafe **Choice**: fixed-option selection, complete option probability vector, confidence.
* TypeSafe **Score**: ordered levels and probability-weighted expected score.
* TypeSafe **Noul**: yes/no probability.
* Cloudflare **Jev** model page.

### Mathematical background

* Wikipedia — **Softmax function**.
* Wikipedia — **Chain rule (probability)**.
* Wikipedia — **LogSumExp**.
* Wikipedia — **Expected value**.

### Papers

1. Vaswani et al. (2017), **Attention Is All You Need**, NeurIPS.
2. Schick & Schütze (2021), **Exploiting Cloze-Questions for Few-Shot Text Classification and Natural Language Inference**, EACL.
3. Zhao et al. (2021), **Calibrate Before Use: Improving Few-shot Performance of Language Models**, ICML.
4. Guo et al. (2017), **On Calibration of Modern Neural Networks**, ICML.

The downloadable Markdown version contains conventional direct links for these references.

## Citation

If you use the Bonsai-Llama-Jev inference engine, it’s method for turning causal language models into a typed-decision engine or it’s Qtype-stratified temperature scaling method, please cite my work:

```bibtex
@software{homberg2026bonsaillamajev,
  author    = {Homberg, Aron},
  title     = {Turning Causal Language Models Into Typed-Decision Engines},
  year      = {2026},
  version   = {5},
  publisher = {GitHub},
  url       = {https://github.com/kyr0/Bonsai-Llama-Jev},
  license   = {MIT}
}
```

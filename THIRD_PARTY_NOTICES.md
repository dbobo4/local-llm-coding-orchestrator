# Third-Party Notices

This repository contains original orchestration, configuration, installation, lifecycle, patch-management, and benchmarking code.

It interoperates with third-party software and models that are not distributed as part of this repository.

## Qwen Code

Project: Qwen Code
Upstream: https://github.com/QwenLM/qwen-code
License: Apache License 2.0

This project was developed and validated against Qwen Code 0.22.3.

The repository includes a compatibility patcher for specific Qwen Code runtime behavior. Qwen Code itself is not redistributed here.

## llama.cpp

Project: llama.cpp
Upstream: https://github.com/ggml-org/llama.cpp
License: MIT License

The reference system was validated with llama.cpp build 10636, commit `4d19b2876`.

llama.cpp binaries and runtime files are not redistributed here.

## Qwen3.8-27B GGUF

Model repository: unsloth/Qwen3.8-27B-GGUF
Model file: `Qwen3.8-27B-UD-Q3_K_XL.gguf`
Upstream: https://huggingface.co/unsloth/Qwen3.8-27B-GGUF
License listed by the model repository: Apache License 2.0

Reference model SHA256:

`8c2a45ff85e7674ca185ec8eb6cdeab0e617ed9d8018caed0b64380eb2a67a5e`

The model weights are not redistributed by this repository.

## Dependency Separation

Users are responsible for obtaining Qwen Code, llama.cpp, and model weights from their respective upstream sources and for complying with the licenses and terms applicable to those components.

The license in this repository applies to this repository's own original source code and documentation unless a file explicitly states otherwise.

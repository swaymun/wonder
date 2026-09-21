# Wonder ASR notices

Wonder's optional local dictation path uses NVIDIA NeMo-Speech.cpp 0.1.0,
distributed under the Apache License 2.0, plus its published third-party
dependencies. The runtime installer uses NVIDIA's verified macOS Apple Silicon
Metal release.

The optional `nvidia/parakeet-tdt-0.6b-v3` Q8 GGUF model is distributed under
CC BY 4.0. The model is downloaded separately, integrity-checked, and stored
under the user's Wonder application-support directory; it is not included in
the app bundle or committed to this repository.

Sources:

- https://github.com/NVIDIA/NeMo-Speech.cpp
- https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3

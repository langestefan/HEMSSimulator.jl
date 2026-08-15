# HEMSSimulator

[![Test workflow status](https://github.com/langestefan/HEMSSimulator.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/langestefan/HEMSSimulator.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/langestefan/HEMSSimulator.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/langestefan/HEMSSimulator.jl)
[![Lint workflow Status](https://github.com/langestefan/HEMSSimulator.jl/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/langestefan/HEMSSimulator.jl/actions/workflows/Lint.yml?query=branch%3Amain)
[![DOI](https://zenodo.org/badge/DOI/FIXME)](https://doi.org/FIXME)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)
[![All Contributors](https://img.shields.io/github/all-contributors/langestefan/HEMSSimulator.jl?labelColor=5e1ec7&color=c0ffee&style=flat-square)](#contributors)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)

## Getting started

```bash
julia --project=. examples/tutorial.jl
```

That script is the walkthrough: a Dutch home with PV, a battery, an EV, a heat pump and a hot water
tank, billed under the four Dutch regulatory scenarios and swept for the battery size worth buying.
It runs on synthetic weather and prices, so it needs no data files and no credentials.

The API is documented in docstrings — `?` in the REPL is the reference.

## How to Cite

If you use HEMSSimulator.jl in your work, please cite using the reference given in [CITATION.cff](https://github.com/langestefan/HEMSSimulator.jl/blob/main/CITATION.cff).

## Contributing

Contributions of any kind are welcome. Please open an issue to discuss anything substantial
before writing code.

The package has no built documentation site; the API is documented in docstrings, so `?` in the
REPL is the reference.

---

### Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

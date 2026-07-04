# Cost Management — AI Grid PoC

A proof-of-concept integrating [Red Hat Cost Management](https://github.com/project-koku/koku) with [OSAC](https://github.com/osac-project) (Open Sovereign AI Console) for the AI Grid sovereign cloud offering.

Standalone Go service that consumes OSAC CloudEvents, meters infrastructure and MaaS usage, applies rates, and produces cost/quota data.

**Status:** 13 of 18 requirements done — [full tracking](docs/implementation-status.md)
**Docs:** [docs/index.md](docs/index.md)

## License

Discovery artifacts and scripts in this repository are part of the
[Koku](https://github.com/project-koku/koku) project. OSAC is a separate
open-source project with its own license.

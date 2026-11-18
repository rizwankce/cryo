# Docs

> How Cryo works and how to run it. Start with the architecture, then the spec for the part you need.

- [architecture.md](architecture.md): how the bay, CLI, MCP server and capsules fit together, and one lease end to end.
- [glossary.md](glossary.md): Cryo's words (bay, capsule, frozen, thawed, lease).
- [spec/setup.md](spec/setup.md): from a new Mac to the first lease; `cryo doctor`; stopping the bay.
- [spec/image.md](spec/image.md): building golden images and putting them into service.
- [spec/bay.md](spec/bay.md): how the bay runs: start-up, lease rules, queue, lease inputs, config.
- [spec/capsule.md](spec/capsule.md): what one capsule is: states, network, files, guest contract.
- [spec/api.md](spec/api.md): the bay's HTTP API.
- [spec/cli.md](spec/cli.md): the `cryo` commands, the MCP tools and the agent skill.
- [spec/deck.md](spec/deck.md): `cryo deck`: several Macs' bays behind one endpoint.

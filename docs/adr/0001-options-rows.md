# Options rows target the installed engine's schema (type/choices)

The API docs describe option rows as `{ key, label, default, help }`, but
the engine the mod is tested on (0.1.88) validates and exports rows with
`type` ("toggle" | "choice") and `choices`. We ship `type`/`choices` so
the mod loads on the installed build; when the engine reaches the docs'
shape, the rows simplify to `{ key, label, default, help }`. The help
texts already fit the 7x17 budget either way.

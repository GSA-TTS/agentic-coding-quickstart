# Troubleshooting — usai-provider kit

These are failure modes specific to the USAi provider kit. They assume you have
applied the kit to a sandbox (`sbx run --kit <kit> opencode <project>`).

## OpenCode shows the wrong providers / no USAi models

**Symptoms:** OpenCode lists generic providers instead of USAi; the custom USAi
model catalog is missing.

**Cause:** the USAi provider config isn't loaded. The kit delivers it by setting
`OPENCODE_CONFIG=/home/agent/usai-config/opencode.jsonc` and dropping that file.
This symptom means the kit wasn't applied to the sandbox, or another kit claimed
the single-valued `OPENCODE_CONFIG` channel (the kit's startup guard warns when
it detects this — check the sandbox's startup logs).

**Fix:**

- Recreate the sandbox with the kit applied: `sbx run --kit <kit> opencode <proj>`.
- Or inject it into an existing sandbox without recreating
  (EXPERIMENTAL): `sbx kit add <sandbox> <kit>`, then restart the agent so it
  re-reads `OPENCODE_CONFIG`.
- Confirm the channel isn't shadowed: `sbx exec <sandbox> -- sh -c 'echo
  $OPENCODE_CONFIG'` should print `/home/agent/usai-config/opencode.jsonc`.

## USAi authentication fails (HTTP 401/403)

**Symptoms:** the agent reaches USAi but every request is rejected.

**Causes & fixes:**

- **Missing/expired key.** The kit reads `USAI_API_KEY` via the sbx proxy; it is
  not stored in the kit. Store/refresh it:
  `sbx secret set-custom -g --host api.gsa.usai.gov --env USAI_API_KEY`.
  USAi keys expire periodically — rotate and update the secret.
- **Key truncated on copy.** The console may visually truncate the key when
  selected by hand; use the console's copy button so the stored secret is
  complete.
- **Stale sandbox-scoped placeholder.** If a key worked in a fresh sandbox but an
  older one still fails, that sandbox may hold an outdated `USAI_API_KEY`
  placeholder from before a rotation. Re-set a sandbox-scoped custom secret:
  `sbx secret set-custom <sandbox> --host api.gsa.usai.gov --env USAI_API_KEY`.

## USAi requests hang or time out

**Symptoms:** requests stall instead of erroring.

**Causes & fixes:**

- **Egress blocked.** Confirm the policy allowed `api.gsa.usai.gov`:
  `sbx policy log <sandbox>` — add any blocked host to the kit's
  `caps.network.allow`. The kit allow-lists `api.gsa.usai.gov` by default.
- **Custom endpoint + proxy.** USAi is a custom (non-built-in) endpoint, so it is
  reached via the network allow-list, not a built-in sbx service proxy. Don't
  expect `sbx secret set -g <service>` style provider proxying to apply to it.

## A model appears in the list but fails at runtime

**Cause:** the generated model catalog can drift from what USAi currently serves
(models added/removed/renamed upstream).

**Fix:** regenerate the catalog from this kit directory: `npm run
sync:usai-models`, then re-apply/recreate the sandbox. The generator only
rewrites the region between the `BEGIN/END GENERATED USAI MODELS` markers.

## The ownership warning appeared at startup

**Symptom:** a `usai-provider: warning: OPENCODE_CONFIG ... is not the USAi kit
config` message in startup logs.

**Cause:** another kit set `OPENCODE_CONFIG` and shadowed this kit's config
(env-var composition is last-wins).

**Fix:** have the other kit contribute its OpenCode config via
`<workspace>/.opencode/opencode.jsonc` instead of setting `OPENCODE_CONFIG` —
OpenCode deep-merges that *over* `OPENCODE_CONFIG`, so both compose. See the
"Co-tenancy" section of the README.

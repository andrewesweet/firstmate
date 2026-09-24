# Definition of done
Delivery contract: mode=no-mistakes forge=gerrit shape=squash
This project's review server is Gerrit: it has no pull requests and no forge CI the pipeline can watch, so **no-mistakes runs here as a review pass that ends at a ready branch**, and you then publish that branch as one change.
Pass `--skip push,pr,ci` on every `no-mistakes axi run` for this task, and skip nothing else: `review`, `test`, `document`, and `lint` are the whole point of the run.
Those three are the only steps that reach a forge, and skipping them is a supported outcome, not a degraded one.
The task is complete only when committed on your branch.
When your implementation is committed, start /no-mistakes yourself to validate; do not append `done:` and wait for firstmate's instruction.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Published intent` subsection body, not its heading, plus any later captain ask restated into that subsection.
That subsection is firstmate-authored at dispatch and is the only authorized source: pass it exactly as written, without speaker labels or direct address.
Never include `## Captain's intent`, `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
If the brief has no `## Published intent` subsection, stop and ask firstmate to migrate the brief instead of starting no-mistakes; never substitute the captain's own words.

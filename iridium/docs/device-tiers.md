# Device capabilities and tuning metadata

Launch readiness uses concrete device and runtime checks: JIT availability,
runtime validation, storage, and game-specific requirements. A blocked launch
should identify the requirement and the action needed to resolve it.

`DeviceTier` values in `packages/profiles`, `packages/runtime`, and runtime-bundle
manifests are internal tuning metadata. They are used by compatibility presets,
runtime defaults, environment overrides, and test fixtures.

User-facing requirements should name the relevant capability. For example,
report insufficient available storage or missing JIT permission. Describe a
performance recommendation as a recommendation, and reserve launch blocks for
requirements enforced by the runtime.

`packages/profiles` owns compatibility profiles, title classification, tuning
defaults, and explicit game policies. Changes to these values need tests against
the runtime decisions that consume them.

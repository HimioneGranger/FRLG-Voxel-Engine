These regression tests need Python 3 and an existing LOVE 11.5 installation. They do not need a ROM, native game assets, an installed game or a headset.

From the repository root:

```text
python tests/regression/run_tests.py --repo . --love /path/to/love --output /path/to/new-test-results
```

On Windows, pass the full path to `love.exe`. The output directory must be new. The runner writes logs and a private test profile there; it does not change engine files.

The suite runs the existing local-loader and field-transition tests, 34 preparation lifecycle checks, and 40 tree-cache checks. Coverage includes separate sheet/voxel preparation state, producer changes, mode cancellation, a real compiled General tree through the CPU codec, exact tree-template roundtrips, malformed payload rejection, batch reconstruction and resource cleanup.

GPU allocations are controlled stubs in the cache suite. These checks do not measure headset performance or replace native-map rendering and visual review.

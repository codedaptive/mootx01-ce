# Installing EideticLib

Until `crates.io` and Swift Package Index publication, depend on EideticLib directly from the repository.

## Rust

### Via git

```toml
[dependencies]
gnomon-kit = { git = "https://github.com/bob-codedaptive/gnomon-kit", tag = "v0.1.0" }
```

### Via local path

```toml
[dependencies]
gnomon-kit = { path = "../gnomon-kit/rust" }
```

The Rust crate lives at `rust/` inside the repository (the workspace root carries the Swift package; the Rust crate is a sibling).

## Swift

### Via Swift Package Manager (git)

```swift
.package(
    url: "https://github.com/bob-codedaptive/gnomon-kit",
    from: "0.1.0"
),
```

then add `"EideticLib"` to your target's dependencies.

### Via local path

```swift
.package(path: "../gnomon-kit"),
```

## Once published

When the package is on `crates.io`, the README's standard `gnomon-kit = "0.1"` form will work. Same for Swift Package Index registry-based discovery.

Until then, the git or path forms above are the supported paths.

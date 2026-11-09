// Compatibility for apps written before the package was renamed to StareGlareReporter.
// `import SnagReporter` and `SnagReporter(...)` keep working, with deprecation warnings.
// New code should add the `StareGlareReporter` library and `import StareGlareReporter`.
@_exported import StareGlareReporter

@available(*, deprecated, renamed: "StareGlareReporter")
public typealias SnagReporter = StareGlareReporter

@available(*, deprecated, renamed: "StareGlareError")
public typealias SnagError = StareGlareError

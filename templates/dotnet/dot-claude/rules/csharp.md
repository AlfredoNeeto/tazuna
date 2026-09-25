---
paths:
  - "**/*.cs"
  - "**/*.csproj"
  - "**/*.props"
  - "**/*.targets"
---

# C# and .NET Rules

- Follow the language version and .NET target configured by the repository.
- Respect nullable reference type settings when enabled.
- Prefer asynchronous APIs for I/O-bound operations when the surrounding API is asynchronous.
- Propagate CancellationToken through asynchronous boundaries when the existing contract supports cancellation.
- Do not use async void except for framework-required event handlers.
- Prefer dependency injection patterns already established by the project.
- Avoid introducing static mutable state.
- Dispose resources according to their ownership and lifetime.
- Preserve existing public contracts unless the requested behavior requires changing them.

Before adding a dependency:

- check whether the repository already provides equivalent functionality;
- confirm compatibility with the project's target framework;
- justify the dependency when it materially changes the solution.
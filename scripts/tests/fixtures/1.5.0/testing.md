---
paths:
  - "**/*Tests/**/*.cs"
  - "**/*Test/**/*.cs"
  - "**/*.Tests/**/*.cs"
  - "**/*.Test/**/*.cs"
---

# .NET Testing Rules

- Follow the testing framework already used by the repository.
- Follow existing naming and organization conventions.
- Prefer tests that verify observable behavior rather than implementation details.
- Keep tests deterministic.
- Avoid network, clock, filesystem, or database dependencies unless the test is explicitly an integration test.
- Do not weaken or remove an existing test merely to make a change pass.
- When fixing a defect, add or update a regression test when practical.
- Keep test setup focused on the behavior being verified.
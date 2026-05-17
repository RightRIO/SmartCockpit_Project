# Contributing to VoYah

Thank you for your interest in contributing to VoYah!

## How to Contribute

### Reporting Issues

- **Bug reports**: Open a [GitHub Issue](https://github.com/rightrio/voyah-scheduler/issues) with the `bug` template.
  - Describe the environment (Linux kernel version, GCC/Clang version).
  - Provide steps to reproduce the issue.
  - Attach `scheduler_*.jsonl` logs if applicable.
- **Feature requests**: Open an issue with the `enhancement` template.
- **Security vulnerabilities**: See [Security Policy](#security-policy).

### Code Contributions

1. **Fork & Clone**

   ```bash
   git clone https://github.com/<your-username>/voyah-scheduler.git
   cd voyah-scheduler
   ```

2. **Create a Branch**

   ```bash
   git checkout -b feat/your-feature-name
   # or
   git checkout -b fix/issue-number-brief-description
   ```

3. **Development Setup**

   ```bash
   # Requires: GCC 7+ or Clang 7+, GNU Make, Linux 4.x+
   make                    # Build
   make test-quick         # Run smoke tests
   ```

4. **Code Style**

   - C++17 standard is required.
   - Follow existing naming conventions in `scheduler.cpp`.
   - No new third-party dependencies.
   - All new code must pass smoke tests: `make test-quick`.

5. **Commit Convention**

   We follow [Conventional Commits](https://www.conventionalcommits.org/):

   ```
   feat: add priority queue support for high-urgency tasks
   fix: handle SIGPIPE when worker crashes during write
   docs: update DESIGN.md with heartbeat mechanism details
   test: add test for SIGUSR1 during graceful shutdown
   refactor: extract IpcChannel into separate header
   ```

6. **Push & Open a Pull Request**

   ```bash
   git push origin feat/your-feature-name
   ```

   Open a PR against `main` and fill out the PR template.
   A maintainer will review your PR within 5 business days.

### Pull Request Checklist

- [ ] `make test` passes on your branch
- [ ] No new compiler warnings introduced
- [ ] New features include corresponding test scripts
- [ ] Documentation (`README*.md`, `DESIGN.md`) updated if applicable
- [ ] Commit messages follow the Conventional Commits format

### Security Policy

Do **not** open public issues for security vulnerabilities.
Please email `security@rightrio.example.com` directly.
We aim to respond within 48 hours and publish a fix in a subsequent release.

### License

By contributing, you agree that your contributions will be licensed under the MIT License.

# Third-party notices

The root `LICENSE` belongs to the JumpCut repository (MIT; © 2026 Egor Kotov) and remains unchanged.

- **strafe** — Riley Hennigh, MIT © 2026. Pinned source base: [`42f69de6007348f7da0f5cba8c5b3ec534f18da2`](https://github.com/rileycx/strafe/tree/42f69de6007348f7da0f5cba8c5b3ec534f18da2). Full license and embedded inherited notices: [third_party/strafe-LICENSE](../third_party/strafe-LICENSE).
- **InstantSpaceSwitcher** — jurplel, MIT © 2026. Original synthetic high-velocity Dock-swipe switching concept. Its MIT notice is preserved in the strafe license.
- **joshuarli/iss** — 0BSD © 2026. macOS 27 raw IOHID payload layout. The 0BSD copyright and terms are preserved in the strafe license.
- **noswoosh** — Max Mathys, MIT © 2026. Compositor-safe macOS 27 gesture-progress/velocity research and tagged-event implementation guidance. Full MIT terms: [third_party/noswoosh-LICENSE](../third_party/noswoosh-LICENSE).

JumpCut is independent and has not been endorsed by the authors of these projects. Changes here are in a separate repository; no upstream commits, PRs, or releases were created.

## Reliable-swipe reference review

The integration was checked against noswoosh
[`14051ab58444c6868f603bee9a4daab12f9f6255`](https://github.com/mmathys/noswoosh/tree/14051ab58444c6868f603bee9a4daab12f9f6255),
joshuarli/iss
[`493b008f2ea8e9215877c39700e8ea3add800e97`](https://github.com/joshuarli/iss/tree/493b008f2ea8e9215877c39700e8ea3add800e97),
and InstantSpaceSwitcher
[`2b883a995d1c81fbc6d75704372a6a0b546bb1ff`](https://github.com/jurplel/InstantSpaceSwitcher/tree/2b883a995d1c81fbc6d75704372a6a0b546bb1ff).
Their preparation, topology, bounded-prediction and visual landing approaches
informed the review. JumpCut's implementation additionally prepares companions,
uses per-display monotonic deadlines and validates exact ordered IDs. No keyboard
rewriting, event-counter filter or automatic focus guard was copied. Existing
full license notices remain unchanged.

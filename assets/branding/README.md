# Xen branding

The five original PNG images are **AI-generated artwork** supplied by
vmintf(minsung). Those supplied files remain unchanged. Their generation
model, prompts and generation date are not recorded here.

`logo-light.png` and `logo-dark.png` are deterministic ImageMagick edits of
`full_logo.png`, prepared for the README on 2026-10-08. The light variant
removes the white background; the dark variant additionally recolors navy
areas near-white. Both retain the original canvas, wordmark geometry and
blue-purple ribbons. These variants inherit the same CC BY 4.0 license.

| File | Purpose |
| --- | --- |
| `full_logo.png` | Original full color wordmark; source for the theme variants |
| `black.png` | Alternative wordmark |
| `website.png` | Website wordmark |
| `symbol.png` | Standalone symbol |
| `github.png` | Square repository/organization image |

The README selects these variants with `<picture>` and
`prefers-color-scheme` media queries. Preparation commands (ImageMagick 6):

```sh
convert assets/branding/full_logo.png -alpha on -fuzz 8% -transparent white assets/branding/logo-light.png
convert assets/branding/logo-light.png -channel RGB -fx '((b-r)<0.25 && (b-g)<0.30) ? 0.96 : u' +channel assets/branding/logo-dark.png
```

ImageMagick is an optional artwork preparation tool; building or running
Xen does not require it.

The artwork is offered under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/),
to the extent of the licensor's applicable copyright and similar rights.
It is excluded from the source code's MIT/Apache license grants. The full
legal text is in [licenses/CC-BY-4.0.txt](../../licenses/CC-BY-4.0.txt), and each
PNG has a corresponding `.license` notice.

CC BY 4.0 permits sharing, modification and commercial use under its terms.
When reusing an image, retain the supplied attribution and notices, link
the license and indicate modifications. No additional usage restriction
is imposed by the AI provenance notice.

Suggested attribution for an unchanged original image:

> Xen branding by vmintf(minsung), AI-generated artwork. Source:
> https://github.com/skystarry-team/Xen/tree/main/assets/branding.
> Licensed under CC BY 4.0: https://creativecommons.org/licenses/by/4.0/.
> No changes made.

For a modified image, replace the last sentence with a description of your
changes. For the README theme variants, retain the supplied background-removal
notice and, for `logo-dark.png`, the lettering recolor notice. The artwork
license does not imply endorsement by the project.

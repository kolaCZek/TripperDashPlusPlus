# Website

Source of https://tripperdash.kolaczek.cz: three static pages, no build step,
no JavaScript, no third-party requests.

- `site/`: exactly what is served (S3 bucket behind CloudFront).
  - `index.html`, `support/index.html`, `privacy.html`, `404.html`, `site.css`
  - `robots.txt`, `sitemap.xml`, `googleff63d25268b6d683.html` (Search Console ownership check; keep it)
  - `fonts/`: Barlow and Barlow Condensed, latin subset (SIL OFL, see `licenses/`)
- `src/`: sources of the generated images.
  - `dash-render.html`: the hero image, a hand-drawn SVG of the Tripper dash (fonts: Inter, latin subset, SIL OFL).
  - `og.html`: the 1200×630 social share image.
- `deploy.sh`: uploads `site/` with the right content types and invalidates CloudFront.

## Edit and preview

Open `site/index.html` in a browser. Links are relative, except in `404.html`,
which CloudFront serves at any path and so uses absolute links.

## Regenerate the images

```sh
cd website/src
chrome --headless=new --hide-scrollbars --allow-file-access-from-files \
  --default-background-color=00000000 --window-size=1200,1200 \
  --screenshot=dash-render.png "file://$PWD/dash-render.html"
chrome --headless=new --hide-scrollbars --allow-file-access-from-files \
  --window-size=1200,630 --screenshot=og.png "file://$PWD/og.html"
```

Then convert to `site/dash-render.webp` (1200 px), `site/dash-render-600.webp`
(600 px) and `site/og-image.jpg`.

## Deploy

```sh
AWS_PROFILE=<profile> website/deploy.sh
```

Credentials come from your AWS CLI setup and never go in this repo. The
profile needs `s3:PutObject` on the bucket and `cloudfront:CreateInvalidation`
on the distribution.

## Content rules

- Product facts come from `README.md` and `docs/app-store-listing.md`.
- No real street names in the images, no Royal Enfield logo.
- No analytics, trackers or CDNs: the privacy policy promises none.

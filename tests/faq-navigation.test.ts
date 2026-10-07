import { describe, expect, it } from 'vitest';
import astroConfig from '../astro.config.mjs';
import { findFaq } from '../src/data/faq';

describe('Explore navigation', () => {
  it('sends the shared map CTA to the interactive map', () => {
    const faq = findFaq('What have you actually built?');
    const exploreLink = faq?.links?.find((link) => link.label === 'Explore the map');

    expect(exploreLink?.href).toBe('/map/');
  });

  it('keeps the former bare Explore URL working', () => {
    expect(astroConfig.redirects?.['/explore/']).toBe('/explore/browse/');
  });
});

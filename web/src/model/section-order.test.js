import { describe, expect, it } from 'vitest';
import { DEFAULT_SECTION_ORDER } from './ui-actions';
import { moveSectionInOrder, orderSections } from './section-order';

const sections = (names) => names.map((name) => ({ name, url: `/api/v1/dust/${name}`, children: [] }));

describe('orderSections', () => {
  it('orders code, audio, data before unmatched when using the default list', () => {
    const input = sections(['data', 'extra', 'code', 'audio']);
    expect(orderSections(input, DEFAULT_SECTION_ORDER).map((s) => s.name)).toEqual([
      'code',
      'audio',
      'data',
      'extra',
    ]);
  });

  it('places unmatched sections where * appears', () => {
    const input = sections(['foo', 'code', 'bar', 'audio']);
    expect(orderSections(input, ['code', '*', 'audio']).map((s) => s.name)).toEqual([
      'code',
      'foo',
      'bar',
      'audio',
    ]);
  });

  it('appends leftovers when * is absent', () => {
    const input = sections(['z', 'code']);
    expect(orderSections(input, ['code']).map((s) => s.name)).toEqual(['code', 'z']);
  });
});

describe('moveSectionInOrder', () => {
  it('moves a section before the drop target and keeps *', () => {
    const input = sections(['code', 'audio', 'data']);
    expect(moveSectionInOrder(input, DEFAULT_SECTION_ORDER, 'data', 'code')).toEqual([
      'data',
      'code',
      'audio',
      '*',
    ]);
  });

  it('is a no-op when names match', () => {
    const input = sections(['code', 'audio', 'data']);
    expect(moveSectionInOrder(input, DEFAULT_SECTION_ORDER, 'code', 'code')).toEqual(
      DEFAULT_SECTION_ORDER,
    );
  });
});

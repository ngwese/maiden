import config from './config-reducers';

describe('config reducer defaults', () => {
  it('defaults minimap to off', () => {
    const state = config(undefined, { type: '@@INIT' });
    expect(state.editor.minimap).toBe(false);
    expect(state.editor.tabSize).toBe(2);
    expect(state.editor.editorTheme).toBe('light');
  });

  it('defaults autoHideSections to off', () => {
    const state = config(undefined, { type: '@@INIT' });
    expect(state.editor.autoHideSections).toBe(false);
  });
});

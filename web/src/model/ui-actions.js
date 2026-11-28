import { REPL_COMPONENT, SIDEBAR_COMPONENT } from '../constants';

export const TOGGLE_COMPONENT = 'TOGGLE_COMPONENT';

export const TOGGLE_CATEGORY = 'TOGGLE_CATEGORY';

export const SIDEBAR_SIZE = 'SIDEBAR_SIZE';
export const REPL_SIZE = 'REPL_SIZE';

export const REORDER_SECTIONS = 'REORDER_SECTIONS';

export const SET_SECTION_HEIGHTS = 'SET_SECTION_HEIGHTS';

// Default explorer section order. "*" matches any section not listed by name.
export const DEFAULT_SECTION_ORDER = ['code', 'audio', 'data', '*'];

export const MIN_SECTION_HEIGHT = 80;

//
// sync actions
//

export const toggleComponent = (name) => ({ type: TOGGLE_COMPONENT, name });

export const toggleCategory = (name, options = {}) => ({
  type: TOGGLE_CATEGORY,
  name,
  exclusive: !!options.exclusive,
  sectionUrls: options.sectionUrls || [],
});

export const sidebarToggle = () => ({ type: TOGGLE_COMPONENT, name: SIDEBAR_COMPONENT });

export const sidebarSize = (width) => ({ type: SIDEBAR_SIZE, width });

export const replToggle = () => ({ type: TOGGLE_COMPONENT, name: REPL_COMPONENT });

export const replSize = (height) => ({ type: REPL_SIZE, height });

export const reorderSections = (order) => ({ type: REORDER_SECTIONS, order });

// heights: { [sectionName]: number } pixel heights for expanded sections
export const setSectionHeights = (heights) => ({ type: SET_SECTION_HEIGHTS, heights });

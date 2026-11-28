import { Set } from 'immutable';

import {
  SIDEBAR_SIZE,
  REPL_SIZE,
  TOGGLE_COMPONENT,
  TOGGLE_CATEGORY,
  REORDER_SECTIONS,
  SET_SECTION_HEIGHTS,
  COLLAPSE_SECTIONS,
  DEFAULT_SECTION_ORDER,
} from './ui-actions';
import { SIDEBAR_COMPONENT, REPL_COMPONENT, CONFIG_COMPONENT } from '../constants';
import { DUST_AUDIO_RESOURCE, DUST_DATA_RESOURCE } from '../api';

/*

ui: {
    hidden: <bool>,
    width: <int>,
}

*/

const initialState = {
  sidebarHidden: false,
  sidebarWidth: 250,
  sidebarMinWidth: 220,
  sidebarMaxWidth: 500,
  replHidden: false,
  replHeight: 160,
  replMinHeight: 100,
  editorMinHeight: 100,
  configHidden: true,
  // code starts expanded; audio/data (and any later non-code sections) start collapsed
  collapsedCategories: new Set([DUST_AUDIO_RESOURCE, DUST_DATA_RESOURCE]),
  sectionOrder: DEFAULT_SECTION_ORDER.slice(),
  sectionHeights: {},
};

const handleToggleComponent = (state, action) => {
  switch (action.name) {
    case SIDEBAR_COMPONENT:
      return { ...state, sidebarHidden: !state.sidebarHidden };

    case REPL_COMPONENT:
      return { ...state, replHidden: !state.replHidden };

    case CONFIG_COMPONENT:
      return { ...state, configHidden: !state.configHidden };

    default:
      return state;
  }
};

const handleToggleCategory = (state, action) => {
  const isCollapsed = state.collapsedCategories.has(action.name);

  if (isCollapsed) {
    // Expanding this section.
    let next = state.collapsedCategories.delete(action.name);
    if (action.exclusive) {
      (action.sectionUrls || []).forEach((url) => {
        if (url !== action.name) {
          next = next.add(url);
        }
      });
    }
    return { ...state, collapsedCategories: next };
  }

  // Collapsing this section.
  return { ...state, collapsedCategories: state.collapsedCategories.add(action.name) };
};

const ui = (state = initialState, action) => {
  switch (action.type) {
    case TOGGLE_COMPONENT:
      return handleToggleComponent(state, action);

    case TOGGLE_CATEGORY:
      return handleToggleCategory(state, action);

    case SIDEBAR_SIZE:
      return { ...state, sidebarWidth: action.width };

    case REPL_SIZE:
      return { ...state, replHeight: action.height };

    case REORDER_SECTIONS:
      return {
        ...state,
        sectionOrder: Array.isArray(action.order)
          ? action.order.slice()
          : DEFAULT_SECTION_ORDER.slice(),
      };

    case SET_SECTION_HEIGHTS:
      return {
        ...state,
        sectionHeights: {
          ...state.sectionHeights,
          ...(action.heights || {}),
        },
      };

    case COLLAPSE_SECTIONS: {
      let next = state.collapsedCategories;
      (action.urls || []).forEach((url) => {
        next = next.add(url);
      });
      if (next === state.collapsedCategories) {
        return state;
      }
      return { ...state, collapsedCategories: next };
    }

    default:
      return state;
  }
};

export default ui;

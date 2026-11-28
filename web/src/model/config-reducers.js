import { UPDATE_EDITOR_CONFIG_SUCCESS, EDITOR_CONFIG_SUCCESS } from './config-actions';

const initialConfigState = {
  editor: {
    tabSize: 2,
    useSoftTabs: true,
    editorTheme: 'light',
    minimap: false,
    autoHideSections: false,
  },
};

const config = (state = initialConfigState, action) => {
  switch (action.type) {
    case UPDATE_EDITOR_CONFIG_SUCCESS:
      return {
        ...state,
        editor: action.value,
      };

    case EDITOR_CONFIG_SUCCESS:
      return {
        ...state,
        editor: action.value,
      };

    default:
      return state;
  }
};

export default config;

import { Map, List } from 'immutable';
import {
  REPL_ENDPOINTS_SUCCESS,
  REPL_CONNECT_DIAL,
  REPL_CONNECT_FAILURE,
  REPL_CONNECT_SUCCESS,
  REPL_CONNECT_CLOSE,
  REPL_RECEIVE,
  REPL_SEND,
  REPL_ECHO,
  REPL_SELECT,
  REPL_CLEAR,
  REPL_UNIT_MAP_SUCCESS,
} from './repl-actions';

/*
-- shape of the repl connection and scrollback buffer state

repl: {
    endpoints: Map({
        componentName: <string>
    })
    connections: Map({
        componentName: { url: ..., socket: ..., error: ... }
    }),
    activeComponent: name,
    scrollbackLimit: <int>,
    buffers: Map({
        componentName: List(<string>, ...)
    })
    history: Map({
        componentName: List(<command>, ...)
    })
}
*/

export const outputAppend = (buffer, limit, line) => {
  const newbuffer = buffer.push(line);
  return newbuffer.size > limit ? newbuffer.shift() : newbuffer;
};

const handleReplEcho = (action, state, input) => {
  // add command to history list
  const history = state.history.get(action.component).unshift(input);
  // echo command to output buffer
  let buffer = state.buffers.get(action.component);
  buffer = outputAppend(buffer, state.scrollbackLimit, input);

  return {
    ...state,
    history: state.history.set(action.component, history),
    buffers: state.buffers.set(action.component, buffer),
  };
};

const handleReplRecieve = (action, state) => {
  let buffer = state.buffers.get(action.component);
  action.data.split('\n').forEach(line => {
    buffer = outputAppend(buffer, state.scrollbackLimit, line);
  });

  return {
    ...state,
    buffers: state.buffers.set(action.component, buffer),
  };
};

const handleReplSend = (action, state, conn) => {
  const socket = conn.get('socket');
  if (!socket) {
    console.log("No socket; can't send", action.value, 'to', action.component);
    return state;
  }
  if (action.component === 'supercollider') {
    // lame, sclang expects commands to be terminated with special command bytes
    socket.send(`${action.value}\x1b`);
  } else {
    socket.send(`${action.value}\n`);
  }

  return handleReplEcho(action, state, action.value);
};

const initialReplState = {
  scrollbackLimit: 200,
  activeRepl: 'norns',
  endpoints: new Map(),
  connections: new Map(),
  buffers: new Map(),
  history: new Map(),
  units: new Map(),
};

const repl = (state = initialReplState, action) => {
  const conn = state.connections.get(action.component);
  let changes;

  switch (action.type) {
    case REPL_ENDPOINTS_SUCCESS:
      console.log('Endpoints:', action.endpoints);
      return { ...state, endpoints: new Map(action.endpoints) };

    case REPL_CONNECT_DIAL:
      console.log('Connecting to [', action.component, '] ', action.endpoint);
      const details = new Map({
        socket: undefined,
        error: undefined,
      });
      return { ...state, connections: state.connections.set(action.component, details) };

    case REPL_CONNECT_FAILURE:
      // let conn = state.connections.get(action.component);
      changes = new Map({
        socket: undefined, // ensure this goes away
        error: action.error,
      });
      return {
        ...state,
        connections: state.connections.set(action.component, conn.merge(changes)),
      };

    case REPL_CONNECT_CLOSE:
      // let conn = state.connections.get(action.component);
      changes = new Map({
        socket: undefined,
        error: undefined,
      });
      return {
        ...state,
        connections: state.connections.set(action.component, conn.merge(changes)),
      };

    case REPL_CONNECT_SUCCESS:
      // let conn = state.connections.get(action.component);
      changes = new Map({
        socket: action.socket,
      });
      return {
        ...state,
        connections: state.connections.set(action.component, conn.merge(changes)),
        buffers: state.buffers.set(action.component, new List()),
        history: state.history.set(action.component, new List()),
      };

    case REPL_RECEIVE:
      return handleReplRecieve(action, state);

    case REPL_SEND:
      return handleReplSend(action, state, conn);

    case REPL_ECHO:
      return handleReplEcho(action, state, action.value);

    case REPL_SELECT:
      return { ...state, activeRepl: action.component };

    case REPL_CLEAR:
      return {
        ...state,
        buffers: state.buffers.set(action.component, new List()),
      };

    case REPL_UNIT_MAP_SUCCESS:
      // console.log('Units:', action.units);
      return {
        ...state,
        units: action.units,
      };

    default:
      return state;
  }
};

export default repl;

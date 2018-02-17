import { Map, List, fromJS } from 'immutable';
import {
    SCRIPT_LIST_SUCCESS,
    SCRIPT_READ_SUCCESS,
    SCRIPT_DIR_SUCCESS,
    SCRIPT_SAVE_SUCCESS,
    SCRIPT_SELECT,
    SCRIPT_CHANGE,

    TOOL_INVOKE,
} from './script-actions';
import { UNTITLED_SCRIPT } from '../constants';

/*

scripts: {
    listing: [
        { name: ..., url: ... },
        { name: ..., url:... , children: [
            <more listings>
        ]}
    ]
    activeBuffer: <url>,
    buffers: Map({
        <url>: {
            name: <string>
            url: <url>,
            modified: <bool>,
            value: <string>,
            selection: ?,
            scrollPosition: ?,
            isFetching: <bool>
        }
    })
}

*/

const initialScriptsState = {
    activeBuffer: undefined,
    listing: new List(),
    buffers: new Map(),
};

const scripts = (state = initialScriptsState, action) => {
    switch (action.type) {
    case SCRIPT_LIST_SUCCESS:
        return { ...state, listing: fromJS(action.value.entries) };

    case SCRIPT_READ_SUCCESS:
        return {
            ...state,
            buffers: state.buffers.set(action.resource, new Map({
                value: action.value,
                modified: false,
            })),
        };

    case SCRIPT_DIR_SUCCESS:
        // console.log("splice", state.listing, action.resource, action.value)
        return {
            ...state,
            listing: spliceDirInfo(state.listing, action.resource, fromJS(action.value.entries))
        };

    case SCRIPT_SAVE_SUCCESS:
        let savedBuffer = state.buffers.get(action.resource).set("modified", false)
        return {
            ...state,
            buffers: state.buffers.set(action.resource, savedBuffer)
        };

    case SCRIPT_SELECT:
        return { ...state, activeBuffer: action.resource };

    case SCRIPT_CHANGE:
        // console.log(action)
        // console.log(state)
        if (action.resource === UNTITLED_SCRIPT) {
            // FIXME: need to implement script new some how
            return state;
        }

        let buffer = state.buffers.get(action.resource);
        // console.log(buffer)
        // TODO: if buffer === nil then create a new "scratch buffer" with a proper resource
        let modified = buffer.get('modified') || buffer.get('value') !== action.value; // FIXME: inefficient?
        let changes = new Map({
            value: action.value,
            modified: modified,
        });
        return { ...state, buffers: state.buffers.set(action.resource, buffer.merge(changes)) };

    case TOOL_INVOKE:
        console.log("tool invoke => ", action.name);
        return state;

    default:
        return state;
    }
};

// FIXME: this seems horrifically inefficient, exhaustive brute force walking of the tree to find one
const spliceDirInfo = (root, target, info) => {
    return root.map(node => {
        // console.log('node =>', node)
        if (node.get('url') === target) {
            // console.log('found node:', node)
            return node.set('children', info)
        } else if (node.children !== undefined) {
            // recurse
            // console.log('recurse node:', node)
            return node.set('children', spliceDirInfo(node.children, target, info))
        }
        return node
    })
}
/*
const keyPath = (root, components) => {
    if (components.size === 0) {
        // we have bottomed out
        return [];
    }
    
    if (root.size === 0 && components.size > 0) {
        console.log("path too deep for node structure")
        return undefined
    }
    
    let name = components.shift();
    let position = root.findIndex(node => node.name === name)
    if (position === -1) {
        return undefined
    }
    let children = keyPath(root.get(position).get('children'), components)
    if (children === undefined) {
        return undefined
    }
    children.unshift(position)
    return children
}
*/

export default scripts;
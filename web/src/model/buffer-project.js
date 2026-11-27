import { Map } from 'immutable';

import { DUST_CODE_RESOURCE } from '../api';
import parsePath from '../path-utils';

// Split a resource URL into non-empty path segments.
const pathSegments = (resource) =>
  String(resource || '')
    .split('/')
    .filter((segment) => segment.length > 0);

// Return the dust/code project name for a resource, or null when the path is
// not under a project directory (top-level code file, project dir itself, etc.).
export const projectForResource = (resource) => {
  const segments = pathSegments(resource);
  for (let i = 0; i < segments.length - 2; i += 1) {
    if (segments[i] === 'dust' && segments[i + 1] === 'code') {
      const projectSegment = segments[i + 2];
      // Need at least one more path segment below the project directory.
      if (i + 3 >= segments.length) {
        return null;
      }
      try {
        return decodeURIComponent(projectSegment);
      } catch (e) {
        return projectSegment;
      }
    }
  }
  return null;
};

// Return the Immutable Map of loaded buffers tagged with the given project name.
export const buffersForProject = (buffers, project) => {
  if (!project || !buffers) {
    return new Map();
  }
  return buffers.filter((buffer) => buffer && buffer.get('project') === project);
};

// Count non-empty path segments in a resource URL.
export const hierarchyDepth = (resource) => pathSegments(resource).length;

// Return [resource, buffer] entries ordered deepest-first; equal depths sort by path.
export const sortBuffersByHierarchyDepth = (buffers) => {
  if (!buffers || buffers.size === 0) {
    return [];
  }
  return buffers
    .entrySeq()
    .toArray()
    .sort(([resourceA], [resourceB]) => {
      const depthDiff = hierarchyDepth(resourceB) - hierarchyDepth(resourceA);
      if (depthDiff !== 0) {
        return depthDiff;
      }
      if (resourceA < resourceB) {
        return -1;
      }
      if (resourceA > resourceB) {
        return 1;
      }
      return 0;
    });
};

// True when the resource is a .lua script at dust/code or at a project root.
export const isResourceRunnable = (resource) => {
  const path = String(resource || '');
  if (!path.endsWith('.lua')) {
    return false;
  }
  const segments = pathSegments(path);
  const dustIndex = segments.findIndex(
    (segment, index) => segment === 'dust' && segments[index + 1] === 'code',
  );
  if (dustIndex < 0) {
    return false;
  }
  // Direct child of dust/code: dust, code, file.lua
  // Direct child of project: dust, code, project, file.lua
  const afterCode = segments.length - (dustIndex + 2);
  return afterCode === 1 || afterCode === 2;
};

// Build the canonical entry-script URL for a project (name matches enclosing dir).
export const getDefaultRunnableResource = ({ project } = {}) => {
  if (!project) {
    return null;
  }
  const encoded = encodeURIComponent(project);
  return `${DUST_CODE_RESOURCE}/${encoded}/${encoded}.lua`;
};

// True when resource is strictly under ancestor on a path-segment boundary.
export const resourceIsBelow = (resource, ancestor) => {
  if (!resource || !ancestor) {
    return false;
  }
  const prefix = ancestor.endsWith('/') ? ancestor : `${ancestor}/`;
  return resource.startsWith(prefix) && resource !== ancestor;
};

// Replace the fromResource prefix with toResource when resource is below it.
export const rewriteResourceBelow = (resource, fromResource, toResource) => {
  if (!resourceIsBelow(resource, fromResource)) {
    return resource;
  }
  return `${toResource}${resource.slice(fromResource.length)}`;
};

// Rekey loaded buffers under fromResource to toResource and recompute project tags.
export const renameLoadedResourcesBelow = (buffers, fromResource, toResource) => {
  if (!buffers || !fromResource || !toResource) {
    return buffers || new Map();
  }

  let next = new Map();
  buffers.forEach((buffer, resource) => {
    if (!resourceIsBelow(resource, fromResource)) {
      next = next.set(resource, buffer);
      return;
    }
    const rewritten = rewriteResourceBelow(resource, fromResource, toResource);
    const updated = buffer ? buffer.set('project', projectForResource(rewritten)) : buffer;
    next = next.set(rewritten, updated);
  });
  return next;
};

// Rewrite descendant listing node URLs under a renamed directory path.
export const rewriteListingUrlsBelow = (nodes, fromResource, toResource) => {
  if (!nodes) {
    return nodes;
  }
  return nodes.map((node) => {
    let next = node;
    const url = node.get('url');
    if (resourceIsBelow(url, fromResource)) {
      next = next.set('url', rewriteResourceBelow(url, fromResource, toResource));
    }
    if (next.has('children')) {
      next = next.set(
        'children',
        rewriteListingUrlsBelow(next.get('children'), fromResource, toResource),
      );
    }
    return next;
  });
};

// Rewrite expandedNodes entries for the renamed resource and anything below it.
export const rewriteExpandedNodesBelow = (expandedNodes, fromResource, toResource) => {
  if (!expandedNodes) {
    return expandedNodes;
  }
  return expandedNodes.map((url) => {
    if (url === fromResource) {
      return toResource;
    }
    if (resourceIsBelow(url, fromResource)) {
      return rewriteResourceBelow(url, fromResource, toResource);
    }
    return url;
  });
};

// Return the basename of a resource URL (final path segment).
export const resourceBasename = (resource) => parsePath(resource).base;

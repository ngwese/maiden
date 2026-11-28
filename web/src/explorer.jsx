import React, { Component } from 'react';
import cx from 'classname';
import Tree, { decorators } from './components/tree';
import treeStyle from './explorer-style';
import './explorer.css';

import ModalContent from './modal-content';
import ModalGetName from './modal-get-name';
import IconButton from './icon-button';
import { ICONS } from './svg-icons';
import api, { isProtectedResource } from './api';
import { USER_DATA_PATH } from './constants';
import { moveSectionInOrder, orderSections } from './model/section-order';
import { MIN_SECTION_HEIGHT } from './model/ui-actions';
import ScrollArea from './components/scroll-area';
import { ensurePanelGestureGuard } from './panel-gesture-guard';

const SECTION_DRAG_TYPE = 'application/x-maiden-section';

const TreeHeader = (props) => {
  const className = cx(
    'explorer-entry',
    'noselect',
    { dirty: props.node.modified },
    { 'active-buffer': props.node.activeBuffer },
    { 'active-selection': props.node.activeNode && !props.node.activeBuffer },
  );
  return <span className={className}>{props.node.name}</span>;
};

const explorerDecorators = {
  ...decorators,
  Header: TreeHeader,
};

const SectionHeader = (props) => {
  let buttons;
  if (props.showTools) {
    buttons = props.tools.map((tool) => (
      <IconButton
        key={tool.name}
        tooltipMessage={tool.tooltipMessage}
        tooltipPosition={tool.tooltipPosition}
        action={() => props.buttonAction(tool.name)}
        icon={tool.icon}
        size="12"
        padding="1"
        color="hsl(0, 0%, 59%)"
        dark
      />
    ));
  }

  return (
    <div
      className={cx('explorer-header', { 'drag-over': props.dragOver })}
      draggable
      onDragStart={props.onDragStart}
      onDragEnd={props.onDragEnd}
      onDragOver={props.onDragOver}
      onDragLeave={props.onDragLeave}
      onDrop={props.onDrop}
      onClick={props.headerClickAction}
    >
      <span className="section-name">{props.name}</span>
      <span
        className={cx('section-tools', { opaque: props.showTools })}
        onClick={(e) => e.stopPropagation()}
        onMouseDown={(e) => e.stopPropagation()}
        draggable={false}
        onDragStart={(e) => e.preventDefault()}
      >
        {buttons}
      </span>
      {props.canResize ? (
        <div
          className="explorer-section-resize"
          data-panel-gesture-block
          onPointerDown={props.onResizePointerDown}
          onClick={(e) => e.stopPropagation()}
          draggable={false}
          onDragStart={(e) => e.preventDefault()}
        />
      ) : null}
    </div>
  );
};

class Section extends Component {
  constructor(props) {
    super(props);
    this.state = {
      showTools: false,
      selectedNode: undefined, // TODO: get rid of this
      dragging: false,
      dragOver: false,
      resizing: false,
    };
  }

  componentDidMount() {
    ensurePanelGestureGuard();
    this.section.onmouseenter = () => {
      this.setState({
        showTools: true,
      });
    };
    this.section.onmouseleave = () => {
      this.setState({
        showTools: false,
      });
    };
    if (!this.isCollapsed()) {
      this.hasBeenExpanded = true;
      this.maybeLoadDirectory();
    }
  }

  componentWillUnmount() {
    this.endResizeListeners();
  }

  componentDidUpdate(prevProps) {
    const wasCollapsed = prevProps.collapsedCategories.has(prevProps.sectionNode.url);
    if (!this.isCollapsed()) {
      this.hasBeenExpanded = true;
    }
    if (wasCollapsed && !this.isCollapsed()) {
      this.maybeLoadDirectory();
    }
  }

  endResizeListeners = () => {
    if (this.capturedResizeTarget && this.capturedResizePointerId != null) {
      try {
        this.capturedResizeTarget.releasePointerCapture(this.capturedResizePointerId);
      } catch (err) {
        // Pointer may already have been released.
      }
      this.capturedResizeTarget = null;
      this.capturedResizePointerId = null;
    }
    if (this.resizeMove) {
      window.removeEventListener('pointermove', this.resizeMove, true);
      this.resizeMove = null;
    }
    if (this.resizeUp) {
      window.removeEventListener('pointerup', this.resizeUp, true);
      window.removeEventListener('pointercancel', this.resizeUp, true);
      this.resizeUp = null;
    }
  };

  maybeLoadDirectory = () => {
    const node = this.props.sectionNode;
    if (node && Array.isArray(node.children) && node.children.length === 0) {
      this.props.directoryRead(node.url);
    }
  };

  isCollapsed = () => this.props.collapsedCategories.has(this.props.sectionNode.url);

  isInSection = (resource) => {
    const sectionUrl = this.props.sectionNode.url;
    return resource === sectionUrl || resource.startsWith(`${sectionUrl}/`);
  };

  onToggle = (node, toggled) => {
    if (node.children) {
      this.props.explorerToggleNode(node, toggled);
      if (toggled && node.children.length === 0) {
        this.props.directoryRead(node.url);
      }
    } else {
      this.props.bufferSelect(node.url);
    }
    this.props.explorerActiveNode(node);
    this.setState({ selectedNode: node });
  };

  onHeaderToggle = () => {
    // Ignore the click that often follows a drag or resize gesture.
    if (this.state.dragging || this.dragMoved || this.state.resizing || this.resizeMoved) {
      return;
    }
    const url = this.props.sectionNode.url;
    if (this.props.autoHideSections && this.isCollapsed()) {
      this.props.explorerToggleCategory(url, {
        exclusive: true,
        sectionUrls: this.props.sectionUrls || [],
      });
      return;
    }
    this.props.explorerToggleCategory(url);
  };

  onResizePointerDown = (event) => {
    // Splitter between this section and the expanded section above it.
    // Drag down: this section shrinks, section above grows; below is unchanged.
    // The last expanded section always fills remaining space, so only the
    // section above gets a locked pixel height when this is last.
    const prevName = this.props.prevExpandedName;
    if (!this.props.canResize || !prevName || !this.props.onSectionResizeStart) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();

    const startY = event.clientY;
    const startHeights = this.props.onSectionResizeStart() || {};
    const name = this.props.name;
    const isLast = this.props.isLastExpanded;
    const startCurrent =
      startHeights[name] ||
      (this.section && Math.round(this.section.getBoundingClientRect().height)) ||
      MIN_SECTION_HEIGHT;
    const startPrev = startHeights[prevName] || MIN_SECTION_HEIGHT;
    const target = event.currentTarget;

    if (target && target.setPointerCapture) {
      target.setPointerCapture(event.pointerId);
      this.capturedResizeTarget = target;
      this.capturedResizePointerId = event.pointerId;
    }

    this.resizeMoved = false;
    this.setState({ resizing: true });

    this.resizeMove = (moveEvent) => {
      moveEvent.preventDefault();
      moveEvent.stopPropagation();
      const delta = Math.round(moveEvent.clientY - startY);
      if (Math.abs(delta) > 2) {
        this.resizeMoved = true;
      }

      // Positive delta (drag down): current smaller, previous larger.
      let nextCurrent = startCurrent - delta;
      let nextPrev = startPrev + delta;

      if (nextCurrent < MIN_SECTION_HEIGHT) {
        nextPrev -= MIN_SECTION_HEIGHT - nextCurrent;
        nextCurrent = MIN_SECTION_HEIGHT;
      }
      if (nextPrev < MIN_SECTION_HEIGHT) {
        nextCurrent -= MIN_SECTION_HEIGHT - nextPrev;
        nextPrev = MIN_SECTION_HEIGHT;
      }

      const heights = { ...startHeights, [prevName]: nextPrev };
      // Keep a recorded height for non-last sections; the last section fills
      // whatever space remains in the panel.
      if (!isLast) {
        heights[name] = nextCurrent;
      }

      if (this.props.explorerSetSectionHeights) {
        this.props.explorerSetSectionHeights(heights);
      }
    };

    this.resizeUp = (upEvent) => {
      if (upEvent) {
        upEvent.preventDefault();
        upEvent.stopPropagation();
      }
      this.endResizeListeners();
      this.setState({ resizing: false });
      window.setTimeout(() => {
        this.resizeMoved = false;
      }, 0);
    };

    window.addEventListener('pointermove', this.resizeMove, true);
    window.addEventListener('pointerup', this.resizeUp, true);
    window.addEventListener('pointercancel', this.resizeUp, true);
  };

  onDragStart = (event) => {
    // Suppress the click that browsers fire on the drag source after a drag.
    this.dragMoved = true;
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.setData(SECTION_DRAG_TYPE, this.props.name);
    event.dataTransfer.setData('text/plain', this.props.name);
    this.setState({ dragging: true });
  };

  onDragEnd = () => {
    this.setState({ dragging: false, dragOver: false });
    // Clear after the trailing click from the gesture.
    window.setTimeout(() => {
      this.dragMoved = false;
    }, 0);
  };

  onDragOver = (event) => {
    if (![...event.dataTransfer.types].includes(SECTION_DRAG_TYPE)) {
      return;
    }
    event.preventDefault();
    event.dataTransfer.dropEffect = 'move';
    if (!this.state.dragOver) {
      this.setState({ dragOver: true });
    }
  };

  onDragLeave = (event) => {
    if (event.currentTarget.contains(event.relatedTarget)) {
      return;
    }
    if (this.state.dragOver) {
      this.setState({ dragOver: false });
    }
  };

  onDrop = (event) => {
    event.preventDefault();
    const draggedName =
      event.dataTransfer.getData(SECTION_DRAG_TYPE) || event.dataTransfer.getData('text/plain');
    // Drop targets never receive dragend; clear drag UI state here.
    this.setState({ dragOver: false, dragging: false });
    if (this.props.onSectionDrop) {
      this.props.onSectionDrop(draggedName, this.props.name);
    }
  };

  onToolClick = (name) => {
    console.log('activeNode: ', this.props.activeNode ? this.props.activeNode.toJS() : undefined);
    const selectedResource = this.props.activeNode ? this.props.activeNode.get('url') : undefined;
    const selectionInSection = selectedResource && this.isInSection(selectedResource);

    if (name === 'new-folder') {
      let selectedNode = this.props.sectionNode;
      if (selectionInSection && this.props.activeNode) {
        selectedNode = {
          name: this.props.activeNode.get('name'),
          url: selectedResource,
        };
        if (this.props.activeNode.has('children')) {
          selectedNode.children = [];
        }
      }
      this.handleNewFolder(selectedNode);
      return;
    }

    if (name === 'add') {
      const sibling = selectionInSection ? selectedResource : this.props.sectionNode.url;
      this.props.scriptCreate(
        sibling, // sibling / parent resource
        undefined, // initial buffer contents
        undefined, // buffer name
        this.getCategory(),
      );
      return;
    }

    // remaining tools need an active selection in this section
    if (this.props.activeNode === undefined || !selectionInSection) {
      return;
    }

    const activeResource = selectedResource;
    const activeResourceIsDir = this.props.activeNode.has('children');

    if (isProtectedResource(activeResource)) {
      console.log('ignoring tool, active resource is protected', activeResource);
      return;
    }

    switch (name) {
      case 'duplicate':
        if (activeResourceIsDir) {
          console.log('duplicate directory not implemented');
        } else {
          this.props.scriptDuplicate(activeResource);
        }
        break;

      case 'remove':
        this.handleRemove(this.props.activeNode);
        break;

      case 'rename':
        this.handleRename(this.props.activeNode);
        break;

      default:
        console.log(name);
        break;
    }
  };

  handleRemove = (selection) => {
    if (selection === undefined) {
      console.log('handleRemove: selection undefined?');
      return;
    }

    const removeModalCompletion = (choice) => {
      console.log('remove:', choice);
      if (choice === 'ok') {
        this.props.resourceDelete(selection.get('url'));
      }
      this.props.hideModal();
    };

    const scriptName = selection.get('name');
    const content = (
      <ModalContent
        message={`Delete "${scriptName}"?`}
        supporting="This operation cannot be undone."
        buttonAction={removeModalCompletion}
      />
    );

    this.props.showModal(content);
  };

  handleRename = (selection) => {
    if (selection === undefined) {
      console.log('handleRename: selection undefined?');
      return;
    }

    const complete = (choice, name) => {
      console.log('rename:', choice, name);
      if (name && choice === 'ok') {
        this.props.resourceRename(selection.get('url'), name, selection.get('virtual') || false);
      }
      this.props.hideModal();
    };

    const initialName = selection.get('name');
    const selectedResource = selection.get('url');
    const content = (
      <ModalGetName
        message="Rename"
        buttonAction={complete}
        selectedResource={selectedResource}
        initialName={initialName}
      />
    );

    this.props.showModal(content);
  };

  handleNewFolder = (selectedNode) => {
    // if no selected node, validate/create against section directory names
    // if selected node is file, validate/create against siblings name
    // if selected node is dir, validate/create against *children* of dir
    const category = this.getCategory();
    const selectedResource = selectedNode.url;
    const selectionIsDir = 'children' in selectedNode;

    const complete = (choice, name) => {
      console.log('new folder:', choice, name);
      if (name && choice === 'ok') {
        const newResource = selectionIsDir
          ? api.childResourceForName(name, selectedResource)
          : api.siblingResourceForName(name, selectedResource, category);
        this.props.directoryCreate(newResource, name, category);
      }
      this.props.hideModal();
    };

    let message = 'New Folder';
    if (selectionIsDir) {
      message += ` (${selectedNode.name})`;
    }

    const content = (
      <ModalGetName
        message={message}
        buttonAction={complete}
        selectedResource={selectedResource}
        category={category}
      />
    );

    this.props.showModal(content);
  };

  getCategory() {
    // listing root lookups and sibling URL fabrication use the dust root name
    return this.props.category;
  }

  render() {
    const data = this.props.sectionNode.children || [];
    const isCollapsed = this.isCollapsed();
    const storedHeight = this.props.sectionHeights && this.props.sectionHeights[this.props.name];
    // Non-last expanded sections lock to pixel heights when multiple are open.
    // The last expanded section always grows to fill the remaining panel space.
    const useFixedHeight =
      !isCollapsed && !this.props.isLastExpanded && this.props.lockHeights && storedHeight;

    // Keep the scroll pane mounted after the first expand so scrollTop survives
    // collapse/show cycles (display:none preserves scroll position).
    const keepScrollPane = !isCollapsed || this.hasBeenExpanded;
    const tree = keepScrollPane ? (
      <Tree
        style={treeStyle}
        data={data}
        onToggle={this.onToggle}
        decorators={explorerDecorators}
      />
    ) : null;

    let sectionStyle;
    if (this.props.isLastExpanded && !isCollapsed) {
      sectionStyle = {
        flexGrow: 1,
        flexShrink: 1,
        flexBasis: 0,
        minHeight: MIN_SECTION_HEIGHT,
      };
    } else if (useFixedHeight) {
      // flex-shrink so oversized stored heights cannot push later sections
      // below the visible explorer area after collapse/expand.
      sectionStyle = {
        flexGrow: 0,
        flexShrink: 1,
        flexBasis: `${storedHeight}px`,
        minHeight: MIN_SECTION_HEIGHT,
      };
    }

    return (
      <div
        className={cx('explorer-section', {
          dragging: this.state.dragging,
          'drag-over': this.state.dragOver,
          'is-expanded': !isCollapsed,
          'is-resizing': this.state.resizing,
        })}
        style={sectionStyle}
        ref={(elem) => {
          this.section = elem;
          if (this.props.sectionDomRef) {
            this.props.sectionDomRef(elem);
          }
        }}
      >
        <SectionHeader
          name={this.props.name}
          tools={this.props.tools}
          buttonAction={this.onToolClick}
          headerClickAction={this.onHeaderToggle}
          showTools={!isCollapsed && this.state.showTools}
          dragOver={this.state.dragOver}
          canResize={!isCollapsed && this.props.canResize}
          onResizePointerDown={this.onResizePointerDown}
          onDragStart={this.onDragStart}
          onDragEnd={this.onDragEnd}
          onDragOver={this.onDragOver}
          onDragLeave={this.onDragLeave}
          onDrop={this.onDrop}
        />
        {keepScrollPane ? (
          <ScrollArea
            className={cx('explorer-section-tree', { 'is-collapsed-pane': isCollapsed })}
          >
            {tree}
          </ScrollArea>
        ) : null}
      </div>
    );
  }
}

const fileTools = [
  {
    name: 'add',
    icon: ICONS.plus,
    tooltipMessage: 'new file',
  },
  {
    name: 'remove',
    icon: ICONS.minus,
    tooltipMessage: 'delete file',
  },
  {
    name: 'duplicate',
    icon: ICONS.copy,
    tooltipMessage: 'duplicate file',
  },
  {
    name: 'new-folder',
    icon: ICONS['folder-plus'],
    tooltipMessage: 'new folder',
  },
  {
    name: 'rename',
    icon: ICONS.pencil,
    tooltipMessage: 'rename file/folder',
  },
];

const sectionSharedProps = (props, sectionUrls, lockHeights) => ({
  tools: fileTools,
  category: USER_DATA_PATH,
  collapsedCategories: props.collapsedCategories,
  autoHideSections: props.autoHideSections,
  sectionHeights: props.sectionHeights || {},
  sectionUrls,
  lockHeights,
  explorerToggleCategory: props.explorerToggleCategory,
  explorerSetSectionHeights: props.explorerSetSectionHeights,
  explorerToggleNode: props.explorerToggleNode,
  explorerActiveNode: props.explorerActiveNode,
  bufferSelect: props.bufferSelect,
  directoryRead: props.directoryRead,
  directoryCreate: props.directoryCreate,
  scriptCreate: props.scriptCreate,
  scriptDuplicate: props.scriptDuplicate,
  resourceDelete: props.resourceDelete,
  resourceRename: props.resourceRename,
  showModal: props.showModal,
  hideModal: props.hideModal,
  activeBuffer: props.activeBuffer,
  activeNode: props.activeNode,
});

class Explorer extends Component {
  constructor(props) {
    super(props);
    this.sectionRefs = {};
    // Track section URLs we have already applied the default collapse policy to.
    this.seenSectionUrls = new Set();
  }

  componentDidMount() {
    this.collapseNewNonCodeSections();
  }

  componentDidUpdate(prevProps) {
    this.collapseNewNonCodeSections();

    const collapsedChanged = prevProps.collapsedCategories !== this.props.collapsedCategories;
    const heightChanged =
      (prevProps.style && prevProps.style.height) !== (this.props.style && this.props.style.height);
    if (collapsedChanged || heightChanged) {
      // Wait a frame so section refs reflect the new expanded/collapsed DOM.
      window.requestAnimationFrame(() => this.fitExpandedSectionHeights());
    }
  }

  // First time we see a non-code section, start it collapsed (code stays open).
  collapseNewNonCodeSections = () => {
    if (!this.props.explorerCollapseSections) {
      return;
    }
    const sectionNodes = this.getOrderedSectionNodes();
    if (sectionNodes.length === 0) {
      return;
    }

    const collapsed = this.props.collapsedCategories;
    const toCollapse = [];
    sectionNodes.forEach((node) => {
      if (this.seenSectionUrls.has(node.url)) {
        return;
      }
      this.seenSectionUrls.add(node.url);
      if (node.name !== 'code' && !(collapsed && collapsed.has(node.url))) {
        toCollapse.push(node.url);
      }
    });

    if (toCollapse.length > 0) {
      this.props.explorerCollapseSections(toCollapse);
    }
  };

  getOrderedSectionNodes = () => {
    const dustNode = (this.props.data || []).find((n) => n.name === USER_DATA_PATH);
    const dustChildren = dustNode && dustNode.children ? dustNode.children : [];
    return orderSections(
      dustChildren.filter((n) => n.children !== undefined),
      this.props.sectionOrder,
    );
  };

  // Keep non-last fixed heights from exceeding the panel so the last section
  // (and anything below) stays reachable after collapse/expand cycles.
  fitExpandedSectionHeights = () => {
    const explorer = this.explorer;
    if (!explorer || !this.props.explorerSetSectionHeights) {
      return;
    }

    const sectionNodes = this.getOrderedSectionNodes();
    const collapsed = this.props.collapsedCategories;
    const expanded = sectionNodes.filter((node) => !(collapsed && collapsed.has(node.url)));
    if (expanded.length < 2) {
      return;
    }

    let collapsedHeaders = 0;
    sectionNodes.forEach((node) => {
      if (!(collapsed && collapsed.has(node.url))) {
        return;
      }
      const el = this.sectionRefs[node.name];
      if (el) {
        collapsedHeaders += el.getBoundingClientRect().height;
      }
    });

    const nonLast = expanded.slice(0, -1);
    const available = explorer.clientHeight - collapsedHeaders;
    // Leave at least a minimum strip for the last expanded section.
    const roomForNonLast = Math.max(0, available - MIN_SECTION_HEIGHT);
    const stored = this.props.sectionHeights || {};

    let sum = 0;
    const measured = nonLast.map((node) => {
      const el = this.sectionRefs[node.name];
      const fallback = el ? Math.round(el.getBoundingClientRect().height) : MIN_SECTION_HEIGHT;
      const height = Math.max(MIN_SECTION_HEIGHT, stored[node.name] || fallback);
      sum += height;
      return { name: node.name, height };
    });

    if (sum <= roomForNonLast) {
      return;
    }

    const next = {};
    let allocated = 0;
    measured.forEach((item, index) => {
      if (index === measured.length - 1) {
        next[item.name] = Math.max(MIN_SECTION_HEIGHT, roomForNonLast - allocated);
        return;
      }
      const scaled = Math.max(
        MIN_SECTION_HEIGHT,
        Math.floor((item.height / sum) * roomForNonLast),
      );
      next[item.name] = scaled;
      allocated += scaled;
    });

    const changed = measured.some((item) => stored[item.name] !== next[item.name]);
    if (changed) {
      this.props.explorerSetSectionHeights(next);
    }
  };

  onLooseToggle = (node, toggled) => {
    if (node.children) {
      this.props.explorerToggleNode(node, toggled);
      if (toggled && node.children.length === 0) {
        this.props.directoryRead(node.url);
      }
    } else {
      this.props.bufferSelect(node.url);
    }
    this.props.explorerActiveNode(node);
  };

  onSectionDrop = (draggedName, targetName) => {
    const dustNode = (this.props.data || []).find((n) => n.name === USER_DATA_PATH);
    const dustChildren = dustNode && dustNode.children ? dustNode.children : [];
    const sectionNodes = dustChildren.filter((n) => n.children !== undefined);
    const sectionNames = new Set(sectionNodes.map((n) => n.name));
    if (!sectionNames.has(draggedName) || !sectionNames.has(targetName)) {
      return;
    }
    const nextOrder = moveSectionInOrder(
      sectionNodes,
      this.props.sectionOrder,
      draggedName,
      targetName,
    );
    if (this.props.explorerReorderSections) {
      this.props.explorerReorderSections(nextOrder);
    }
  };

  // Snapshot current expanded section heights before a resize drag so siblings keep size.
  onSectionResizeStart = () => {
    const dustNode = (this.props.data || []).find((n) => n.name === USER_DATA_PATH);
    const dustChildren = dustNode && dustNode.children ? dustNode.children : [];
    const sectionNodes = orderSections(
      dustChildren.filter((n) => n.children !== undefined),
      this.props.sectionOrder,
    );
    const heights = {};
    sectionNodes.forEach((node) => {
      if (this.props.collapsedCategories && this.props.collapsedCategories.has(node.url)) {
        return;
      }
      const el = this.sectionRefs[node.name];
      if (el) {
        heights[node.name] = Math.round(el.getBoundingClientRect().height);
      }
    });
    if (this.props.explorerSetSectionHeights) {
      this.props.explorerSetSectionHeights(heights);
    }
    return heights;
  };

  render() {
    const dustNode = (this.props.data || []).find((n) => n.name === USER_DATA_PATH);
    const dustChildren = dustNode && dustNode.children ? dustNode.children : [];
    const sectionNodes = orderSections(
      dustChildren.filter((n) => n.children !== undefined),
      this.props.sectionOrder,
    );
    const looseNodes = dustChildren.filter((n) => n.children === undefined);
    const sectionUrls = sectionNodes.map((n) => n.url);
    const expandedCount = sectionNodes.filter(
      (n) => !(this.props.collapsedCategories && this.props.collapsedCategories.has(n.url)),
    ).length;
    const lockHeights = expandedCount >= 2;
    const shared = sectionSharedProps(this.props, sectionUrls, lockHeights);

    let lastExpandedName;
    for (let i = sectionNodes.length - 1; i >= 0; i -= 1) {
      const node = sectionNodes[i];
      if (!(this.props.collapsedCategories && this.props.collapsedCategories.has(node.url))) {
        lastExpandedName = node.name;
        break;
      }
    }

    // Drop refs for sections that no longer exist.
    Object.keys(this.sectionRefs).forEach((name) => {
      if (!sectionNodes.some((n) => n.name === name)) {
        delete this.sectionRefs[name];
      }
    });

    return (
      <div
        className={`explorer${this.props.hidden ? ' hidden' : ''}`} // FIXME: change this to use classname
        style={{ height: this.props.style && this.props.style.height }}
        ref={(elem) => (this.explorer = elem)}
      >
        {looseNodes.length > 0 ? (
          <ScrollArea className="explorer-section-tree explorer-loose-tree">
            <Tree
              style={treeStyle}
              data={looseNodes}
              onToggle={this.onLooseToggle}
              decorators={explorerDecorators}
            />
          </ScrollArea>
        ) : null}
        {sectionNodes.map((sectionNode, index) => {
          const isExpanded = !(
            this.props.collapsedCategories && this.props.collapsedCategories.has(sectionNode.url)
          );
          let prevExpandedName;
          if (isExpanded) {
            for (let i = index - 1; i >= 0; i -= 1) {
              const candidate = sectionNodes[i];
              if (!(
                this.props.collapsedCategories && this.props.collapsedCategories.has(candidate.url)
              )) {
                prevExpandedName = candidate.name;
                break;
              }
            }
          }
          return (
            <Section
              key={sectionNode.url}
              name={sectionNode.name}
              sectionNode={sectionNode}
              {...shared}
              prevExpandedName={prevExpandedName}
              isLastExpanded={sectionNode.name === lastExpandedName}
              canResize={lockHeights && !!prevExpandedName}
              onSectionDrop={this.onSectionDrop}
              onSectionResizeStart={this.onSectionResizeStart}
              sectionDomRef={(el) => {
                if (el) {
                  this.sectionRefs[sectionNode.name] = el;
                } else {
                  delete this.sectionRefs[sectionNode.name];
                }
              }}
            />
          );
        })}
      </div>
    );
  }
}

export default Explorer;

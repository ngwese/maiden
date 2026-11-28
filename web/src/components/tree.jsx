import React, { Component } from 'react';

import './tree.css';

const Loading = ({ style }) => <div style={style}>loading...</div>;

// Lucide chevron-right / chevron-down (https://lucide.dev/icons/)
const ChevronRight = ({ size }) => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{ display: 'block' }}
  >
    <path d="m9 18 6-6-6-6" />
  </svg>
);

const ChevronDown = ({ size }) => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{ display: 'block' }}
  >
    <path d="m6 9 6 6 6-6" />
  </svg>
);

const Toggle = ({ style, toggled }) => {
  const { height, width } = style;
  const size = Math.max(height || 12, width || 12);

  return (
    <span style={style.base} className="explorer-tree-chevron">
      {toggled ? <ChevronDown size={size} /> : <ChevronRight size={size} />}
    </span>
  );
};

const Header = ({ node, style }) => (
  <div style={style.base}>
    <div style={style.title}>{node.name}</div>
  </div>
);

class Container extends Component {
  render() {
    const { style, decorators, terminal, onClick, node } = this.props;
    const ToggleDecorator = decorators.Toggle;
    const HeaderDecorator = decorators.Header;
    const rowStyle = {
      ...style.container,
      display: 'flex',
      alignItems: 'center',
    };

    return (
      <div onClick={onClick} style={rowStyle} role="presentation">
        {!terminal ? (
          <span className="explorer-tree-toggle">
            <ToggleDecorator style={style.toggle} toggled={!!node.toggled} />
          </span>
        ) : (
          <span className="explorer-tree-toggle-spacer" />
        )}
        <HeaderDecorator node={node} style={style.header} />
      </div>
    );
  }
}

export const decorators = {
  Loading,
  Toggle,
  Header,
  Container,
};

class TreeNode extends Component {
  onClick = () => {
    const { node, onToggle } = this.props;
    if (onToggle) {
      onToggle(node, !node.toggled);
    }
  };

  render() {
    const { node, style, decorators: propsDecorators, onToggle } = this.props;
    const nodeDecorators = { ...propsDecorators, ...(node.decorators || {}) };
    const terminal = !node.children;
    const headerStyle = { ...style, container: style.container };
    const NodeContainer = nodeDecorators.Container;

    return (
      <li style={style.base}>
        <NodeContainer
          decorators={nodeDecorators}
          node={node}
          onClick={this.onClick}
          style={headerStyle}
          terminal={terminal}
        />
        {node.toggled ? this.renderChildren(nodeDecorators, onToggle) : null}
      </li>
    );
  }

  renderChildren(nodeDecorators, onToggle) {
    const { node, style, decorators: propsDecorators } = this.props;
    const LoadingDecorator = nodeDecorators.Loading;

    if (node.loading) {
      return (
        <ul style={style.subtree} className="explorer-tree-subtree">
          <li>
            <LoadingDecorator style={style.loading} />
          </li>
        </ul>
      );
    }

    let { children } = node;
    if (!Array.isArray(children)) {
      children = children ? [children] : [];
    }

    return (
      <ul style={style.subtree} className="explorer-tree-subtree">
        {children.map((child, index) => (
          <TreeNode
            key={child.url || child.id || index}
            decorators={propsDecorators}
            node={child}
            onToggle={onToggle}
            style={style}
          />
        ))}
      </ul>
    );
  }
}

class Tree extends Component {
  render() {
    const { data: propsData, onToggle, style, decorators: propsDecorators } = this.props;
    const data = Array.isArray(propsData) ? propsData : [propsData];
    const treeDecorators = propsDecorators || decorators;

    return (
      <ul className="explorer-tree" style={style.tree.base}>
        {data.map((node, index) => (
          <TreeNode
            key={node.url || node.id || index}
            decorators={treeDecorators}
            node={node}
            onToggle={onToggle}
            style={style.tree.node}
          />
        ))}
      </ul>
    );
  }
}

export default Tree;

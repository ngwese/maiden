export default {
  tree: {
    base: {
      listStyle: 'none',
      backgroundColor: 'var(--neutral-background-default)',
      margin: 0,
      padding: 0,
      color: 'var(--neutral-medium-default)',
    },
    node: {
      base: {
        position: 'relative',
      },
      container: {},
      toggle: {
        base: {
          position: 'relative',
          display: 'block',
          lineHeight: 0,
          color: 'var(--neutral-medium-default)',
        },
        height: 12,
        width: 12,
      },
      header: {
        base: {
          color: 'var(--neutral-medium-default)',
        },
        connector: {},
        title: {
          lineHeight: '24px',
          verticalAlign: 'middle',
        },
      },
      subtree: {
        listStyle: 'none',
        paddingLeft: '14px',
      },
      loading: {
        color: 'var(--accent1-background-default)',
      },
    },
  },
};

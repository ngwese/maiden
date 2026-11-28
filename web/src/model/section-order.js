import { DEFAULT_SECTION_ORDER } from './ui-actions';

// Sort section nodes by an order list. Named entries are placed explicitly;
// "*" consumes any remaining unmatched sections (stable relative order).
export const orderSections = (sections, order) => {
  const orderList = order && order.length > 0 ? order : DEFAULT_SECTION_ORDER;
  const remaining = sections.slice();
  const result = [];

  orderList.forEach((key) => {
    if (key === '*') {
      result.push(...remaining);
      remaining.length = 0;
      return;
    }
    const index = remaining.findIndex((section) => section.name === key);
    if (index >= 0) {
      result.push(...remaining.splice(index, 1));
    }
  });

  // Sections left over when the order list has no "*"
  result.push(...remaining);
  return result;
};

// Move draggedName before targetName in the concrete display order, then
// append "*" when the previous order used it as a catch-all.
export const moveSectionInOrder = (sections, order, draggedName, targetName) => {
  if (!draggedName || !targetName || draggedName === targetName) {
    return order && order.length > 0 ? order.slice() : DEFAULT_SECTION_ORDER.slice();
  }

  const concrete = orderSections(sections, order).map((section) => section.name);
  const from = concrete.indexOf(draggedName);
  const to = concrete.indexOf(targetName);
  if (from < 0 || to < 0) {
    return order && order.length > 0 ? order.slice() : DEFAULT_SECTION_ORDER.slice();
  }

  concrete.splice(from, 1);
  concrete.splice(to, 0, draggedName);

  const previous = order && order.length > 0 ? order : DEFAULT_SECTION_ORDER;
  if (previous.includes('*')) {
    return [...concrete, '*'];
  }
  return concrete;
};

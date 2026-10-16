import type { DashboardData, FilterState } from '../data/types';

/**
 * Every view receives the same props. The FilterBar is mounted once by the app shell
 * (one row above the panel) and scopes every view; views never own filter state, they
 * only read `filter` and may request a change through `onFilterChange` (e.g. clicking a
 * Set name in Overview narrows `filter.set`).
 */
export interface ViewProps {
  data: DashboardData;
  filter: FilterState;
  onFilterChange: (next: FilterState) => void;
}

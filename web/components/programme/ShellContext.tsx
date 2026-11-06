'use client';
import * as React from 'react';
import type { RoleLevel } from '@/lib/role-context';

// W2-00 — serializable snapshot of the server-resolved shell context for
// client components (ReportBreachButton, future filter bars). The server
// layout is the source of truth; nothing here grants access — RLS does.

export interface ProgrammeShellState {
  userId: string;
  levels: RoleLevel[];
  brandName: string | null;
  logoUrl: string | null;
  accentHex: string | null;
  /** selected programme, when inside /programmes/[id] */
  programmeId: string | null;
  programmeName: string | null;
  clientOrgId: string | null;
  clientName: string | null;
  /** FR-BRN-05 */
  showAttribution: boolean;
}

const Ctx = React.createContext<ProgrammeShellState | null>(null);

export function ProgrammeShellProvider({
  value,
  children,
}: {
  value: ProgrammeShellState;
  children: React.ReactNode;
}) {
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useProgrammeShell(): ProgrammeShellState | null {
  return React.useContext(Ctx);
}

import React from "react";
import { buildApiHeaders } from "../config";
import {
  getGrantedCorePermissions,
  hasGrantedCorePermission,
} from "../permissions/corePermissions";
import {
  PERMISSION_STAND_PROJECTS_CREATE,
  PERMISSION_STAND_PROJECTS_DELETE,
  PERMISSION_STAND_PROJECTS_EXECUTE,
  PERMISSION_STAND_PROJECTS_UPDATE,
} from "../permissions/navigationPermissions";
import { standProjectsLabels } from "../labels/standProjectsLabels";

export type FairStandPageProps = {
  mode: "new" | "edit";
  projectId?: string;
  customerId?: string;
  onBackToList: () => void;
};

export function FairStandPage({ mode, projectId, customerId, onBackToList }: FairStandPageProps) {
  const hostRef = React.useRef<HTMLDivElement>(null);
  const granted = React.useMemo(() => getGrantedCorePermissions(), []);
  const capabilities = React.useMemo(
    () => ({
      canCreate: hasGrantedCorePermission(granted, PERMISSION_STAND_PROJECTS_CREATE),
      canUpdate: hasGrantedCorePermission(granted, PERMISSION_STAND_PROJECTS_UPDATE),
      canDelete: hasGrantedCorePermission(granted, PERMISSION_STAND_PROJECTS_DELETE),
      canExecute: hasGrantedCorePermission(granted, PERMISSION_STAND_PROJECTS_EXECUTE),
    }),
    [granted],
  );

  const onBackToListRef = React.useRef(onBackToList);
  onBackToListRef.current = onBackToList;

  React.useEffect(() => {
    const host = hostRef.current;
    if (!host || (mode === "new" && !customerId)) return undefined;

    let cancelled = false;
    let unmount: (() => void) | undefined;

    // Fair Stand proje açılış ölçümü "Düzenle"den sayar (projectOpenTiming EDITOR_ROUTE_MARK).
    if (mode === "edit") performance.mark("fs:editor-route");
    void import("@fair-stand/mountFairStand.js").then(({ mountFairStand }) => {
      if (cancelled || !hostRef.current) return;
      unmount = mountFairStand(hostRef.current, {
        catalogHeaders: buildApiHeaders(),
        initialProjectId: mode === "edit" ? projectId : undefined,
        customerId: mode === "new" ? customerId : undefined,
        capabilities,
      });
      const sidebar = hostRef.current?.querySelector("#sidebar");
      const intro = sidebar?.querySelector(".sidebar-intro");
      if (!sidebar || !intro || sidebar.querySelector(".sidebar-back")) return;
      const button = sidebar.ownerDocument.createElement("button");
      button.type = "button";
      button.className = "sidebar-back";
      button.textContent = `← ${standProjectsLabels.backToList}`;
      button.addEventListener("click", () => onBackToListRef.current());
      sidebar.insertBefore(button, intro);
    });

    return () => {
      cancelled = true;
      unmount?.();
    };
  }, [capabilities, customerId, mode, projectId]);

  return (
    <div className="fair-stand-standalone" data-testid="fair-stand-standalone">
      <div
        ref={hostRef}
        className="fair-stand-host"
        data-testid="fair-stand-host"
      >
        {mode === "new" && !customerId ? <p>{standProjectsLabels.missingCustomer}</p> : null}
      </div>
    </div>
  );
}

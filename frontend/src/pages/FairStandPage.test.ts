import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { FairStandPage } from "./FairStandPage";

const here = dirname(fileURLToPath(import.meta.url));

describe("FairStandPage standalone host", () => {
  it("renders a full-viewport host without the top chrome bar or PageShell", () => {
    const html = renderToStaticMarkup(
      React.createElement(FairStandPage, {
        mode: "new",
        onBackToList: () => undefined,
      }),
    );
    expect(html).toContain('data-testid="fair-stand-standalone"');
    expect(html).toContain('data-testid="fair-stand-host"');
    expect(html).toContain("fair-stand-standalone");
    expect(html).not.toContain("fair-stand-chrome");
    expect(html).not.toContain("page-shell");
    expect(html).not.toContain("sidebar");
    expect(html).not.toContain("app-topbar");
  });

  it("marks the edit route before loading Fair Stand so the open timing counts from Düzenle", () => {
    const source = readFileSync(join(here, "FairStandPage.tsx"), "utf8");
    const mark = source.indexOf('if (mode === "edit") performance.mark("fs:editor-route");');
    expect(mark).toBeGreaterThan(-1);
    expect(mark).toBeLessThan(source.indexOf('void import("@fair-stand/mountFairStand.js")'));
  });

  it("mounts Fair Stand with catalog headers, project id, and capabilities", () => {
    const source = readFileSync(join(here, "FairStandPage.tsx"), "utf8");
    expect(source).toContain("catalogHeaders: buildApiHeaders()");
    expect(source).toContain("initialProjectId");
    expect(source).toContain("customerId: mode === \"new\" ? customerId : undefined");
    expect(source).toContain("capabilities");
    expect(source).toContain('import("@fair-stand/mountFairStand.js")');
    expect(source).toContain('button.className = "sidebar-back"');
    expect(source).toContain('hostRef.current?.querySelector("#sidebar")');
    expect(source).toContain("sidebar.insertBefore(button, intro)");
    expect(source).not.toContain('querySelector("iframe")');
    expect(source).not.toContain("contentDocument");
    expect(source).not.toContain("FairStandEmbed");
    expect(source).not.toContain("PageShell");
  });
});

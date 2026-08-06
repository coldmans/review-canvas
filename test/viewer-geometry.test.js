const assert = require("node:assert/strict");
const test = require("node:test");

const { normalizeRect, semanticNodeID } = require("../Resources/viewer-geometry.js");

test("normalizes a transformed Mermaid node against the rendered SVG", () => {
    const svgRect = { left: 100, top: 50, width: 500, height: 250 };
    const nodeRect = { left: 225, top: 100, width: 100, height: 50 };

    assert.deepEqual(normalizeRect(svgRect, nodeRect), {
        x: 0.25,
        y: 0.2,
        width: 0.2,
        height: 0.2
    });
});

test("rejects geometry when the rendered SVG has no measurable size", () => {
    assert.equal(
        normalizeRect(
            { left: 0, top: 0, width: 0, height: 100 },
            { left: 0, top: 0, width: 10, height: 10 }
        ),
        null
    );
});

test("rejects non-finite node geometry", () => {
    assert.equal(
        normalizeRect(
            { left: 0, top: 0, width: 100, height: 100 },
            { left: Number.NaN, top: 0, width: 10, height: 10 }
        ),
        null
    );
});

test("uses Mermaid source data-id instead of a render-specific DOM id", () => {
    const node = {
        id: "mermaid-viewer-2-flowchart-API-0",
        dataset: { id: "API" }
    };

    assert.equal(semanticNodeID(node, "mermaid-viewer-2"), "API");
});

test("removes the render id prefix when Mermaid omits data-id", () => {
    const node = {
        id: "mermaid-viewer-7-custom-node",
        dataset: {}
    };

    assert.equal(semanticNodeID(node, "mermaid-viewer-7"), "custom-node");
});

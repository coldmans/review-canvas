(function (root, factory) {
    const geometry = factory();

    if (typeof module === "object" && module.exports) {
        module.exports = geometry;
    }

    if (root) {
        root.ReviewCanvasGeometry = geometry;
    }
}(typeof globalThis !== "undefined" ? globalThis : this, function () {
    function normalizeRect(containerRect, itemRect) {
        const containerLeft = Number(containerRect?.left);
        const containerTop = Number(containerRect?.top);
        const containerWidth = Number(containerRect?.width);
        const containerHeight = Number(containerRect?.height);
        const itemLeft = Number(itemRect?.left);
        const itemTop = Number(itemRect?.top);
        const itemWidth = Number(itemRect?.width);
        const itemHeight = Number(itemRect?.height);
        const values = [
            containerLeft,
            containerTop,
            containerWidth,
            containerHeight,
            itemLeft,
            itemTop,
            itemWidth,
            itemHeight
        ];

        if (!values.every(Number.isFinite) || containerWidth <= 0 || containerHeight <= 0) {
            return null;
        }

        return {
            x: (itemLeft - containerLeft) / containerWidth,
            y: (itemTop - containerTop) / containerHeight,
            width: itemWidth / containerWidth,
            height: itemHeight / containerHeight
        };
    }

    function semanticNodeID(node, renderID) {
        const sourceID = String(
            node?.dataset?.id ?? node?.getAttribute?.("data-id") ?? ""
        ).trim();
        if (sourceID) {
            return sourceID;
        }

        const domID = String(node?.id ?? "").trim();
        if (!domID) {
            return null;
        }

        const prefix = renderID ? `${renderID}-` : "";
        return prefix && domID.startsWith(prefix)
            ? domID.slice(prefix.length)
            : domID;
    }

    return { normalizeRect, semanticNodeID };
}));

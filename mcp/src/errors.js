export class ReviewCanvasError extends Error {
  constructor(code, message, details = undefined, options = undefined) {
    super(message, options);
    this.name = "ReviewCanvasError";
    this.code = code;
    if (details !== undefined) {
      this.details = details;
    }
  }
}

export function fail(code, message, details = undefined, options = undefined) {
  throw new ReviewCanvasError(code, message, details, options);
}

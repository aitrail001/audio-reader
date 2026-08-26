export { packageId } from "./packageId";

export default {
  fetch(): Response {
    return new Response("Not Implemented", { status: 501 });
  },
  queue(batch: MessageBatch): void {
    void batch;
  },
} satisfies ExportedHandler;

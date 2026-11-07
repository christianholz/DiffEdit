/** One modal owner at a time, including errors raised during another prompt. */
export class DialogQueue {
  private tail: Promise<unknown> = Promise.resolve();
  constructor(
    private readonly present: (
      message: string,
      choices: string[],
    ) => Promise<string>,
  ) {}
  choose(message: string, choices: string[]): Promise<string> {
    const request = this.tail.then(() => this.present(message, choices));
    this.tail = request.catch(() => {});
    return request;
  }
}

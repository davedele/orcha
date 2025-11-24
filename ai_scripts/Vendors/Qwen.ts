import OpenAI from "openai";
import type { AskOptions, ChatInstance, VendorConfig } from "../GenAI";

type Role = "user" | "assistant";

export class QwenChat implements ChatInstance {
    private readonly client: OpenAI;
    private readonly model: string;
    private readonly vendorConfig?: VendorConfig;
    private readonly messages: { role: Role; content: string }[] = [];
    private instructions?: string;

    constructor(
        apiKey: string,
        model: string,
        vendorConfig?: VendorConfig,
    ) {
        this.client = new OpenAI({
            apiKey,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        });
        this.model = model;
        this.vendorConfig = vendorConfig;
    }

    async ask(
        userMessage: string | null,
        options: AskOptions = {},
    ): Promise<string | { messages: any[] }> {
        if (userMessage === null) {
            return { messages: this.messages };
        }

        const wantStream = options.stream !== false;
        if (typeof options.system === "string") {
            this.instructions = options.system;
        }

        this.messages.push({ role: "user", content: userMessage });

        const chatMessages = [
            ...(this.instructions ? [{ role: "system", content: this.instructions }] : []),
            ...this.messages.map((m) => ({ role: m.role, content: m.content })),
        ];

        const params: Record<string, any> = {
            model: this.model,
            messages: chatMessages,
        };

        if (typeof options.temperature === "number") {
            params.temperature = options.temperature;
        }
        if (typeof options.max_tokens === "number") {
            params.max_tokens = options.max_tokens;
        }

        let visible = "";

        if (wantStream) {
            const stream: AsyncIterable<any> = await (this.client.chat.completions.create as any)({
                ...params,
                stream: true,
            });
            for await (const chunk of stream) {
                const delta: any = chunk.choices?.[0]?.delta ?? {};
                if (delta.content) {
                    process.stdout.write(delta.content);
                    visible += delta.content;
                }
            }
            process.stdout.write("\n");
        } else {
            const resp: any = await (this.client.chat.completions.create as any)(params);
            const message = resp?.choices?.[0]?.message;
            const content = message?.content ?? "";
            process.stdout.write(content + "\n");
            visible = content;
        }

        this.messages.push({ role: "assistant", content: visible });
        return visible;
    }
}

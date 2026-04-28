# Benchmarks — BitNet 1.58-bit Models

> Tested on Azure Standard_D4as_v5 (4 vCPU AMD EPYC, 16GB RAM, Ubuntu 22.04, x86_64)
> All models quantized to I2_S using bitnet.cpp

## Test Setup

- **Hardware:** Azure Standard_D4as_v5 (4 vCPU, 16GB RAM)
- **Models:** Falcon3-3B, 7B, 10B Instruct 1.58-bit
- **Quantization:** I2_S (1.58-bit ternary)
- **Threads:** 4 (matching vCPU count)
- **Temperature:** 0.7, repeat_penalty: 1.1
- **Categories tested:** 12

---

## Speed

| Model | Parameters | GGUF Size | Tokens/sec | Avg Response Time |
|---|---|---|---|---|
| Falcon3-3B-Instruct | 3B | 2.1GB | **~23 tok/s** | 4-6s |
| Falcon3-7B-Instruct | 7B | 3.1GB | **~12 tok/s** | 8-12s |
| Falcon3-10B-Instruct | 10B | 3.8GB | **~10 tok/s** | 10-15s |

---

## Summary Matrix

| # | Task | 3B | 7B | 10B |
|---|---|---|---|---|
| 1 | Small Talk | ✅ | ✅ | ✅ |
| 2 | Intent Classification | ❌ | ✅ | ⚠️ |
| 3 | Sentiment Analysis | ⚠️ | ✅ | ⚠️ |
| 4 | Topic Classification | ✅ | ✅ | ✅ |
| 5 | Entity Extraction (NER) | ⚠️ | ⚠️ | ✅ |
| 6 | Reading Comprehension | ❌ | ✅ | ✅ |
| 7 | Summarization | ✅ | ✅ | ⚠️ |
| 8 | Code Explanation | ✅ | ✅ | ✅ |
| 9 | Formal Rewriting | ✅ | ✅ | ✅ |
| 10 | Bullet Point Extraction | ⚠️ | ✅ | ✅ |
| 11 | Simple Math | ❌ | ⚠️ | ⚠️ |
| 12 | Email Summary + Actions | ✅ | ✅ | ✅ |
| | **Score** | **6/12** | **10/12** | **9/12** |

---

## Detailed Results by Category

### 1. Small Talk

**Prompt:** `Hey, how are you doing today?`

| Model | Response | Verdict |
|---|---|---|
| 3B | "You could ask me a question or seek..." | ✅ Functional but brief |
| 7B | "I'm just a computer program, so I don't have feelings or emotions, but thank you for asking! How can I assist you today?" | ✅ Natural, self-aware |
| 10B | "I'm just a computer program, so I don't have feelings or emotions. But thank you for asking! Is there anything else I can help you with?" | ✅ Natural, polished |

**Analysis:** All models handle casual conversation well. 7B and 10B give nearly identical, natural responses. 3B is functional but less engaging.

---

### 2. Intent Classification

**System:** `Classify intent as one word: complaint, inquiry, request, or greeting.`
**Prompt:** `I want to cancel my subscription and get a refund immediately`
**Expected:** `request`

| Model | Response | Verdict |
|---|---|---|
| 3B | "greeting" | ❌ Completely wrong |
| 7B | "request" | ✅ **Correct** |
| 10B | "inquiry" | ⚠️ Close but not exact |

**Analysis:** Only 7B nails the exact label. 3B fails entirely. 10B understands the intent but picks a less precise label. For production intent classification, 7B is the clear winner.

---

### 3. Sentiment Analysis

**System:** `Classify sentiment as one word: positive, negative, neutral, or mixed.`
**Prompt:** `The food was amazing but the service was terrible. We waited 45 minutes.`
**Expected:** `mixed`

| Model | Response | Verdict |
|---|---|---|
| 3B | "negative" | ⚠️ Picked dominant negative, missed positive |
| 7B | "mixed" | ✅ **Only correct answer** |
| 10B | "negative" | ⚠️ Same as 3B |

**Analysis:** Mixed sentiment is genuinely hard for small models. They tend to latch onto the stronger emotion. 7B is the only model that correctly identifies the mixed nature — a significant quality advantage.

---

### 4. Topic Classification

**System:** `Classify into one category: technology, sports, politics, health, finance, entertainment.`
**Prompt:** `NVIDIA stock surged 12% after record $22B quarterly revenue from AI chip demand.`

| Model | Response | Verdict |
|---|---|---|
| 3B | "technology" | ✅ Reasonable (AI chips = tech) |
| 7B | "finance" | ✅ **More precise** (stock surge = finance) |
| 10B | "finance" | ✅ **More precise** |

**Analysis:** Both "technology" and "finance" are defensible. 7B and 10B correctly prioritize the financial angle (stock price, revenue), while 3B focuses on the subject matter (AI chips).

---

### 5. Entity Extraction (NER)

**System:** `Extract entities as JSON with keys: person, organization, location, date.`
**Prompt:** `Elon Musk announced on Jan 15 2025 that Tesla will open a factory in Berlin with BMW.`

| Model | Response | Verdict |
|---|---|---|
| 3B | `{"name": "Tesla", "organization": ["company"], "location": ["Berlin"], "date": ["15, 2025"]}` | ⚠️ Missing person (Elon Musk), malformed date |
| 7B | `{"location": "Berlin", "organization": "BMW", "date": "Jan 15, 2025"}` | ⚠️ Missing person, missing Tesla |
| 10B | `{"person": ["Elon Musk"], "organization": ["Tesla", "BMW"], "location": ["Berlin"], "date": "Jan 15 2025"}` | ✅ **All entities correct** |

**Analysis:** Entity extraction is where model size matters most. Only 10B correctly identifies all four entity types including the person. This is the 10B's strongest advantage — if your use case requires precise NER, the 10B is worth the speed tradeoff.

---

### 6. Reading Comprehension (RAG-style)

**System:** `Answer based ONLY on the context. Be concise.`
**Prompt:** `Context: Enterprise plan costs $99/month with unlimited storage, dedicated account manager, and 99.9% SLA. What does it include and cost?`

| Model | Response | Verdict |
|---|---|---|
| 3B | "Enterprise plan costs 850 dollars a year..." | ❌ **Hallucinated price** ($850 not in context) |
| 7B | "Enterprise plan includes unlimited storage, a dedicated account manager, and has a 99.9% SLA. The cost is $99 per month." | ✅ **Complete and accurate** |
| 10B | "The enterprise plan includes unlimited storage and a dedicated account manager. It also has a high SLA of 99.9%. The monthly cost is $99." | ✅ **Complete and accurate** |

**Analysis:** Critical finding — 3B hallucinates facts not present in the context. This makes it **unsafe for RAG/retrieval applications**. 7B and 10B both faithfully extract information from the provided context without hallucination.

---

### 7. Summarization

**System:** `Summarize in 2 sentences.`
**Prompt:** `The ECB held rates at 4.5% after 10 hikes since July 2022. President Lagarde wants more evidence inflation heads to 2% before cutting. Markets expect first cut June 2024. Eurozone narrowly avoided recession in H2 2023.`

| Model | Response | Verdict |
|---|---|---|
| 3B | "The ECB's rate hikes were a sign of economic uncertainty, with the president aiming for further data on inflationary expectations and the potential for cuts in July 2024. Eurozone economies have remained resilient..." | ✅ Good, slight date inaccuracy (July vs June) |
| 7B | "The ECB hiked rates nine times since July, bringing them to the highest level since 1956 and maintaining a key rate of 4.5%." | ✅ Good but added unsourced claim ("since 1956") |
| 10B | "The ECB hiked rates to 4.5% after falling below 1% in July 2022." | ⚠️ Factual error ("falling below 1%") |

**Analysis:** All models produce readable summaries, but each introduces minor inaccuracies. 3B is closest to the source material. For summarization, model size doesn't guarantee better accuracy — all need fact-checking.

---

### 8. Code Explanation

**Prompt:** `What does this Python code do in one sentence: sorted(set(words), key=lambda w: -len(w))[:5]`

| Model | Response | Verdict |
|---|---|---|
| 3B | "The code sorts all unique words by their lengths, and then limits the output to the first five elements." | ✅ Correct |
| 7B | "Takes a list of words, removes duplicates by converting to a set, sorts by word length in descending order. Returns the first five elements." | ✅ Detailed and correct |
| 10B | "Removes duplicates, sorts the words in descending order based on their length, and selects the first five elements." | ✅ Correct |

**Analysis:** All three models correctly explain the code. 7B gives the most detailed explanation. Code understanding is a strength across all model sizes.

---

### 9. Formal Rewriting

**System:** `Rewrite in professional formal tone.`
**Prompt:** `hey dude meeting pushed to next week cuz client bailed lmk if that works`

| Model | Response | Verdict |
|---|---|---|
| 3B | "Subject: Meeting Adjusted for Client's Availability - Next Week. Dear [Client's Name]," | ✅ Good email structure |
| 7B | "Good morning [Client's Name], I would like to inform you of an upcoming engagement which has been rescheduled for the subsequent week. Kindly advise on your availability." | ✅ **Most polished, natural tone** |
| 10B | "Subject: Client Meeting Reschedule to Next Week. Dear [Client's Name]," | ✅ Professional but brief |

**Analysis:** 7B produces the most natural, complete rewrite. 3B and 10B both default to email subject+greeting format without completing the body. For writing tasks, 7B has the best balance of formality and completeness.

---

### 10. Bullet Point Extraction

**System:** `Extract key points as a bullet list.`
**Prompt:** `All employees must submit timesheets by Friday 5pm, use the new project tool for tracking, attend standup at 9am Monday, and complete security training by month end.`

| Model | Response | Verdict |
|---|---|---|
| 3B | "- Employees must ensure all work hours are accurately recorded using a new project management tool... - All employees should submit their weekly timesheets..." | ⚠️ Verbose, added extra interpretation |
| 7B | "- Submit timesheets by Friday at 5 pm\n- Use the new Project Tool for tracking\n- Attend Standup Meetings Monday at 9 am\n- Complete Security Training by Month End" | ✅ **Clean, all 4 points, no extras** |
| 10B | "- Submit timesheets by Friday 5 pm\n- Use the new project tool to track work\n- Attend standup meeting on Monday at 9 am\n- Complete security training by end of month" | ✅ **Clean, all 4 points** |

**Analysis:** 7B and 10B both produce clean, accurate bullet lists. 3B adds unnecessary interpretation and merges points. For structured extraction, 7B+ is recommended.

---

### 11. Simple Math

**Prompt:** `What is 25% of 200?`
**Expected:** `50`

| Model | Response | Verdict |
|---|---|---|
| 3B | "25/100 × 200 = 5" | ❌ **Wrong answer** (said 5 instead of 50) |
| 7B | "To calculate 25% of 200, you can multiply..." | ⚠️ Started explaining but didn't finish |
| 10B | "To find 25% of 200, you multiply..." | ⚠️ Started explaining but didn't finish |

**Analysis:** Math is the weakest category across all models. 3B gets the wrong answer entirely. 7B and 10B begin the correct approach but run out of tokens before completing. With higher `max_tokens`, they would likely produce the correct answer. For math-heavy use cases, these models are not recommended.

---

### 12. Email Summary + Action Items

**System:** `Summarize this email in one sentence and list action items.`
**Prompt:** `Q3 launch moved from Sep 15 to Oct 1 due to regulatory delays. Marketing must update materials by Sep 20. Budget increased 15% for compliance. Design needs to finalize landing page by Sep 25.`

| Model | Response | Verdict |
|---|---|---|
| 3B | "- Update marketing materials\n- Ensure legal documentation finalized\n- Adjust budget allocation" | ✅ Actions listed, added extra inference ("legal documentation") |
| 7B | "Q3 launch was delayed; marketing must update by Sept. 20, budget increased 15%, and design must complete landing page by Sept. 25" | ✅ **Concise one-sentence summary with all details** |
| 10B | "The Q3 launch has been postponed due to regulatory delays. Marketing must update materials by September 20, while the budget will be increased by 15%. Design team needs to finalize landing page by Sep 25." | ✅ **Most detailed and complete** |

**Analysis:** All models handle email summarization well. 7B gives the most concise summary. 10B provides the most complete breakdown. 3B adds inferred actions not in the original email.

---

## Model Recommendations

### By Use Case

| Use Case | Recommended Model | Why |
|---|---|---|
| **Chatbot / Q&A** | 7B | Best balance of quality and speed |
| **Entity Extraction / NER** | 10B | Only model to extract all entity types |
| **Sentiment / Intent Classification** | 7B | Only model to get "mixed" sentiment correct |
| **RAG / Reading Comprehension** | 7B or 10B | 3B hallucinates — unsafe for RAG |
| **Summarization** | 7B | Most concise, fewest errors |
| **Code Tasks** | Any | All perform equally well |
| **Text Rewriting** | 7B | Most natural, complete output |
| **Fast Responses (latency-sensitive)** | 3B | 2x faster than 7B |
| **Structured Data Extraction** | 10B | Best JSON output, all fields |

### By Deployment

| Scenario | Model | VM Size |
|---|---|---|
| Demo / tryout | 3B | 2 vCPU, 4GB RAM |
| Production API | 7B | 4 vCPU, 8GB RAM |
| High-quality tasks | 10B | 4+ vCPU, 12GB RAM |
| All models (user choice) | 3B + 7B + 10B | 4 vCPU, 16GB RAM |

---

## Key Findings

1. **Instruct models are essential** — Base models (BitNet 2B, Llama3-8B) produce garbage on structured tasks. Only Falcon3 Instruct models follow system prompts reliably.

2. **7B is the sweet spot** — Scores 10/12 on our benchmark, highest of all models. The 10B only wins on NER and detailed responses, while being 20% slower.

3. **3B hallucinates on comprehension** — Invented a price ($850) not in the source text. This makes it unsafe for any RAG or fact-extraction use case.

4. **Sentiment "mixed" is hard** — Only 7B correctly identifies mixed sentiment. Both 3B and 10B default to the dominant emotion.

5. **Math is universally weak** — All models struggle with arithmetic. Not recommended for math-heavy applications.

6. **Code understanding is strong** — All three models correctly explain code, regardless of size. This is a strength of the Falcon3 architecture.

7. **Speed vs quality tradeoff is real** — 3B is 2.3x faster than 10B, but scores 6/12 vs 9/12. The 7B at 12 tok/s with 10/12 score is the optimal balance.

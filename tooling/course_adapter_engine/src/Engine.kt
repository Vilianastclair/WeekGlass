package org.weekglass.courseadapter

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.util.Locale

/** A single in-memory request. User input selects a registered ID, never a Java class or URL. */
class TermWeeksRequired : RuntimeException()

object Engine {
    private val gson = GsonBuilder().serializeNulls().disableHtmlEscaping().create()
    private val registry by lazy {
        val stream = checkNotNull(Engine::class.java.getResourceAsStream("/courseadapter/registry.json"))
        stream.bufferedReader(Charsets.UTF_8).use { JsonParser.parseReader(it).asJsonObject }
    }
    private val byAlias by lazy {
        val entries = mutableMapOf<String, JsonObject>()
        for (item in registry["adapters"].asJsonArray) {
            val a = item.asJsonObject
            for (alias in listOf(a["id"].asString) + a["aliases"].asJsonArray.map { it.asString }) {
                val prior = entries.put(alias.lowercase(Locale.ROOT), a)
                check(prior == null || prior == a) { "Ambiguous adapter alias" }
            }
        }
        entries
    }

    private fun fail(code: String, msg: String) = gson.toJson(mapOf("ok" to false,"code" to code,"message" to msg))
    private fun JsonObject.string(key: String): String? =
        get(key)?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isString }?.asString

    @JvmStatic fun handle(request: String): String {
        if (request.length > MAX_REQUEST) return fail("INVALID_REQUEST","课表输入过大。")
        val obj = try { JsonParser.parseString(request).asJsonObject } catch (_: Exception) {
            return fail("INVALID_REQUEST","请求不是 JSON 对象。")
        } catch (_: StackOverflowError) { return fail("INVALID_REQUEST","输入结构过深。") }
        when (obj.string("op")) {
            "list" -> return gson.toJson(mapOf("ok" to true, "revision" to registry["revision"], "adapters" to registry["adapters"]))
            "parse" -> {}
            else -> return fail("INVALID_REQUEST","需要 list 或 parse 操作。")
        }
        val adapter = obj.string("adapter")?.let { byAlias[it.trim().lowercase(Locale.ROOT)] }
            ?: return fail("UNKNOWN_ADAPTER","该适配器不在当前离线引擎内。")
        val source = obj.string("source")?.trimStart('\uFEFF') ?: return fail("INVALID_REQUEST","请提供课表内容。")
        if (source.isBlank()) return fail("NO_COURSES","没有可解析的课程。")
        val lead = source.trimStart()
        val kind = adapter["inputKind"].asString
        if (kind=="json" && !(lead.startsWith("{") || lead.startsWith("[")) ||
            kind=="csv" && (lead.startsWith("<") || !source.contains(','))) {
            return fail("UNSUPPORTED_INPUT",adapter["requirement"].asString)
        }
        if (kind=="html" && !lead.contains('<')) return fail("UNSUPPORTED_INPUT",adapter["requirement"].asString)
        val id = adapter["id"].asString
        val term = obj.get("termWeeks")
        val termWeeks = if (term == null) null else {
            val n = if (term.isJsonPrimitive && term.asJsonPrimitive.isNumber) term.asString.toIntOrNull() else null
            if (n == null || n !in 1..53) return fail("INVALID_REQUEST","学期教学周数须为 1 至 53 之间的整数。")
            n
        }

        return try {
            val parser = parserFor(id,source)
            parser.confirmedTermWeeks = termWeeks
            val courses = parser.generateCourseList()
            if (courses.isEmpty()) return fail("NO_COURSES","未在该课表中识别到课程。")
            if (courses.size > 20000) return fail("PARSE_ERROR","课程条目数超出范围。")
            val warnings = mutableListOf<String>()
            // Optional metadata may live outside the captured table. Keep successful course rows.
            fun <T> optional(label:String, block:()->T):T? = try { block() } catch (_: Exception) {
                warnings.add(label); null
            }
            val table = optional("timeTable") { parser.generateTimeTable() }
            val schedule = table?.let { mapOf("name" to it.name, "timeList" to it.timeList.map { slot ->
                mapOf("node" to slot.node, "startTime" to clock(slot.startTime), "endTime" to clock(slot.endTime))
            }) }
            gson.toJson(mapOf("ok" to true, "adapter" to id, "courses" to courses.map { c ->
                mapOf("name" to c.name,"day" to c.day,"room" to c.room,"teacher" to c.teacher,
                    "startNode" to c.startNode,"endNode" to c.endNode,"startWeek" to c.startWeek,
                    "endWeek" to c.endWeek,"type" to c.type,"credit" to c.credit,"note" to c.note,
                    "startTime" to clock(c.startTime),"endTime" to clock(c.endTime))
            }, "timeTable" to schedule, "startDate" to optional("startDate"){parser.getStartDate()},
                "tableName" to optional("tableName"){parser.getTableName()}, "nodes" to optional("nodes"){parser.getNodes()},
                "maxWeek" to optional("maxWeek"){parser.getMaxWeek()}, "metadataUnavailable" to warnings))
        } catch (_: TermWeeksRequired) { fail("NEED_TERM_WEEKS","该课表没有学期长度，请确认本学期有多少个教学周。") }
          catch (_: Exception) { fail("PARSE_ERROR","课表内容与该适配器的版式不符。") }
          catch (_: StackOverflowError) { fail("PARSE_ERROR","课表层级过深。") }
    }

    private val clockPattern = Regex("""(\d{1,2}):(\d{2})""")
    private fun clock(value:String):String {
        val m=clockPattern.matchEntire(value) ?: return ""
        val h=m.groupValues[1].toInt()
        val minute=m.groupValues[2].toInt()
        return if (h in 0..23 && minute in 0..59) m.groupValues[1].padStart(2,'0')+":"+m.groupValues[2] else ""
    }
    internal const val MAX_REQUEST = 8 * 1024 * 1024
}

object Main {
    @JvmStatic fun main(args:Array<String>) {
        val input = System.`in`.bufferedReader(Charsets.UTF_8)
        val chars=CharArray(8192)
        val text=StringBuilder()
        while (text.length <= Engine.MAX_REQUEST) {
            val n = input.read(chars)
            if (n < 0) break
            text.append(chars,0,n)
        }
        val writer = System.out.writer(Charsets.UTF_8)
        writer.write(Engine.handle(text.toString()))
        writer.flush()
    }
}


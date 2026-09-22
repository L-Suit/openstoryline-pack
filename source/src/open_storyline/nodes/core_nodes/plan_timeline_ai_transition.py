from typing import List, Dict, Tuple, Union, Any
from src.open_storyline.config import Settings
from open_storyline.nodes.node_state import NodeState
from open_storyline.nodes.core_nodes.base_node import BaseNode, NodeMeta
from open_storyline.nodes.node_schema import PlanTimelineAITransitionInput
from open_storyline.utils.register import NODE_REGISTRY


@NODE_REGISTRY.register()
class PlanTimelineAITransitionNode(BaseNode):

    meta = NodeMeta(
        name="plan_timeline_ai_transition",
        description=(
            "Create a coherent timeline for AI generated transitions, mounting the "
            "generated script as subtitles distributed across each group's clips. "
        ),
        node_id="plan_timeline_ai_transition",
        node_kind="plan_timeline",
        require_prior_kind=["split_shots", "generate_ai_transition", "generate_script", "music_rec"],
        default_require_prior_kind=["split_shots", "generate_ai_transition", "generate_script", "music_rec"],
        next_available_node=["render_video"],
    )
    
    input_schema = PlanTimelineAITransitionInput


    def __init__(self, server_cfg: Settings) -> None:
        super().__init__(server_cfg)

    async def default_process(
        self,
        node_state: NodeState,
        inputs: Dict[str, Any],
    ) -> Any:
        return await self.process(node_state, inputs)

    async def process(self, node_state: NodeState,  inputs: Dict[str, Any]) -> Any:
        clips = inputs.get("split_shots", {}).get("clips", [])
        generate_ai_transition = inputs.get("generate_ai_transition", {})
        groups = generate_ai_transition.get("groups", [])
        transition_info = generate_ai_transition.get("transition_info", {})
        music = inputs.get("music_rec", {}).get("bgm", {})
        generate_script = inputs.get("generate_script", {}) or {}

        image_duration_ms = inputs.get("image_duration_ms", 2000)
        clips_by_clip_id = {clip.get("clip_id", ""): clip for clip in clips}

        current_cursor = 0
        video_segments = []
        bgm_segments = []
        group_spans: Dict[str, Dict[str, int]] = {}

        for group in groups:
            group_id = group.get("group_id")
            group_start_cursor = current_cursor
            clip_ids = group.get("clip_ids")
            for clip in clip_ids:
                if self._is_transition_clip_id(clip):
                    current_transition_info = transition_info.get(clip, {})
                    current_transition_duration = current_transition_info.get("source_ref", {}).get("duration_ms", 0)
                    video_segments.append({
                        "clip_id": clip,
                        "group_id": group.get("group_id"),
                        "kind": "video",
                        "fps": current_transition_info.get("fps", 0),
                        "size": [
                            current_transition_info.get("source_ref", {}).get("width", 0),
                            current_transition_info.get("source_ref", {}).get("height", 0),
                        ],
                        "source_path": current_transition_info.get("path", ""),
                        "source_window": {
                            "start": 0,
                            "end": current_transition_duration,
                            "duration": current_transition_duration
                        },
                        "timeline_window": {
                            "start": current_cursor,
                            "end": current_cursor + current_transition_duration,
                            "duration": current_transition_duration
                        },
                        "playback_rate": 1.0
                    })
                    current_cursor += current_transition_duration
                else:
                    current_clip_info = clips_by_clip_id.get(clip, {})
                    current_clip_kind = current_clip_info.get("kind")
                    current_clip_source_ref = current_clip_info.get("source_ref", {})
                    current_clip_duration = image_duration_ms if current_clip_info.get("kind") == "image" else current_clip_info.get("source_ref", {}).get("duration", 0)
                    video_segments.append({
                        "clip_id": clip,
                        "group_id": group.get("group_id"),
                        "kind": current_clip_kind,
                        "fps": current_clip_info.get("fps", 0),
                        "size": [
                            current_clip_info.get("source_ref", {}).get("width", 0),
                            current_clip_info.get("source_ref", {}).get("height", 0),
                        ],
                        "source_path": current_clip_info.get("path", ""),
                        "source_window": {
                            "start": 0,
                            "end": current_clip_duration,
                            "duration": current_clip_duration
                        },
                        "timeline_window": {
                            "start": current_cursor,
                            "end": current_cursor + current_clip_duration,
                            "duration": current_clip_duration
                        },
                        "playback_rate": 1.0
                    })
                    current_cursor += current_clip_duration

            if group_id is not None and current_cursor > group_start_cursor:
                group_spans[group_id] = {"start": group_start_cursor, "end": current_cursor}

        subtitle_segments = self._build_subtitle_track(
            generate_script=generate_script,
            group_spans=group_spans,
        )

        bgm_segments = self._build_bgm_track(
            background_music=music,
            total_duration_ms=current_cursor,
        )

        return {
            "tracks": {
                "video": video_segments,
                "subtitles": subtitle_segments,
                "voiceover": [],
                "bgm": bgm_segments,
            }
        }

    def _build_subtitle_track(
        self,
        *,
        generate_script: Dict[str, Any],
        group_spans: Dict[str, Dict[str, int]],
    ) -> List[Dict[str, Any]]:
        """Distribute each group's subtitle units across that group's timeline span.

        The AI-transition timeline has no TTS/beat timing to anchor subtitles to, so
        each group's span (from its first clip to its last) is split proportionally to
        the character length of each subtitle unit.
        """
        subtitle_segments: List[Dict[str, Any]] = []
        if not generate_script or not group_spans:
            return subtitle_segments

        for group_script in generate_script.get("group_scripts", []) or []:
            group_id = group_script.get("group_id")
            span = group_spans.get(group_id)
            if not span:
                continue

            units = group_script.get("subtitle_units", []) or []
            if not units:
                continue

            span_start = span["start"]
            span_duration = span["end"] - span["start"]
            if span_duration <= 0:
                continue

            unit_lengths = [max(len((unit.get("text") or "").strip()), 1) for unit in units]
            total_length = sum(unit_lengths)

            cursor = span_start
            for index_in_group, (unit, unit_length) in enumerate(zip(units, unit_lengths)):
                text = (unit.get("text") or "").strip()
                # Last unit absorbs any rounding remainder so the track ends exactly on span end.
                if index_in_group == len(units) - 1:
                    unit_end = span["end"]
                else:
                    unit_end = cursor + int(span_duration * unit_length / total_length)

                if text and unit_end > cursor:
                    subtitle_segments.append({
                        "group_id": group_id,
                        "unit_id": unit.get("unit_id"),
                        "index_in_group": index_in_group,
                        "text": text,
                        "timeline_window": {
                            "start": cursor,
                            "end": unit_end,
                        },
                    })
                cursor = unit_end

        return subtitle_segments

    def _is_transition_clip_id(self, clip_id: Any) -> bool:
        return isinstance(clip_id, str) and clip_id.startswith("transition_")
    
    def _build_bgm_track(
        self,
        *,
        background_music: dict[str, Any] | None,
        total_duration_ms: int,
    ) -> List[Dict[str, Any]]:
        bgm_segments: List[Dict[str, Any]] = []
        if not background_music:
            return bgm_segments

        music_duration_ms = int(background_music.get("duration", 0))
        if music_duration_ms <= 0:
            return bgm_segments

        timeline_cursor_ms: int = 0
        source_cursor_ms: int = 0
        loop_index = 0

        while timeline_cursor_ms < total_duration_ms:
            remaining_timeline_ms = total_duration_ms - timeline_cursor_ms
            remaining_source_ms = max(0, music_duration_ms - source_cursor_ms)

            if remaining_source_ms <= 0:
                source_cursor_ms = 0
                loop_index += 1
                continue

            segment_duration_ms = min(remaining_timeline_ms, remaining_source_ms)
            if segment_duration_ms <= 0:
                break

            bgm_segments.append(
                {
                    "bgm_id": background_music.get("bgm_id"),
                    "path": background_music.get("path"),
                    "source_window": {"start": source_cursor_ms, "end": source_cursor_ms + segment_duration_ms},
                    "loop_idx": loop_index,
                }
            )

            timeline_cursor_ms += segment_duration_ms
            source_cursor_ms += segment_duration_ms

            if timeline_cursor_ms < total_duration_ms and source_cursor_ms >= music_duration_ms:
                source_cursor_ms = 0
                loop_index += 1

        return bgm_segments

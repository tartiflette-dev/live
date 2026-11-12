// Instant d'une vidéo, comme l'affiche un lecteur : « 0:07 », « 4:05 »,
// « 1:02:09 » (même forme que ReplaysHelper#replay_timecode). Secondes
// absentes ou négatives : « 0:00 ».
export function videoTimecode(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${secs}` : `${minutes}:${secs}`;
}

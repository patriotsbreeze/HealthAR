"""Poses two MANO hands into the CPR grip and writes them for Blender.

MANO (Romero et al., SIGGRAPH Asia 2017) is a hand model learned from 3D scans, so its hands look
real. Its licence is for non-commercial research only: fine for this demo, not for a shipped product
without a commercial licence from the Max Planck Institute. The model files are not in this repo.
Register at https://mano.is.tue.mpg.de, download "Models & Code", and point this at the folder with
MANO_LEFT.pkl and MANO_RIGHT.pkl.

    python tools/make_mano_hands.py ~/Downloads/mano out.npz

Needs torch, numpy and smplx. It writes, in the app's hand space (heel of the lower hand at the
origin on the chest, +y up, fingers along -z away from the rescuer, who kneels toward +z), in metres:

- lower_faces, upper_faces: triangles.
- lower_frames, upper_frames: [steps, 778, 3] vertices from open hands to the finished grip, for the
  video's lacing. The last step is the grip the app draws.
"""

import pickle
import sys
from pathlib import Path

import numpy as np
import torch
import smplx

STEPS = 24


# --- Reading the official files without chumpy ---------------------------------------------------


class _Chumpy:
    """Stands in for chumpy's arrays when unpickling. Only their values are kept."""

    def __init__(self, *args, **kwargs):
        pass

    def __setstate__(self, state):
        self.__dict__.update(state if isinstance(state, dict) else {"x": state})

    def array(self):
        for key in ("x", "a", "r"):
            if key in self.__dict__:
                value = self.__dict__[key]
                return value.array() if isinstance(value, _Chumpy) else np.asarray(value)
        raise ValueError(f"no values in {list(self.__dict__)}")


class _Unpickler(pickle.Unpickler):
    def find_class(self, module, name):
        if module.startswith("chumpy"):
            return _Chumpy
        return super().find_class(module, name)


def clean(path, out):
    """The same model with every chumpy array turned into a plain one, which smplx can load."""
    with open(path, "rb") as f:
        data = _Unpickler(f, encoding="latin1").load()
    data = {k: (v.array() if isinstance(v, _Chumpy) else v) for k, v in data.items()}
    with open(out, "wb") as f:
        pickle.dump(data, f)
    return data


# --- Posing ---------------------------------------------------------------------------------------

# MANO's 15 hand joints, three per finger from the knuckle out.
INDEX, MIDDLE, LITTLE, RING, THUMB = (0, 1, 2), (3, 4, 5), (6, 7, 8), (9, 10, 11), (12, 13, 14)
FINGERS = (INDEX, MIDDLE, RING, LITTLE)
# Vertex ids of the fingertips and joint ids of the knuckles, MANO's own.
WRIST, INDEX_KNUCKLE, MIDDLE_KNUCKLE, LITTLE_KNUCKLE = 0, 1, 4, 7


def model(folder, side, scratch):
    cleaned = scratch / f"MANO_{side}.pkl"
    data = clean(folder / f"MANO_{side}.pkl", cleaned)
    hand = smplx.MANO(str(cleaned), is_rhand=side == "RIGHT", use_pca=False, flat_hand_mean=True)
    # Its mean pose is a relaxed, partly closed hand, so each joint's share of it points the way that
    # joint bends. That gives every joint's curl axis from the model itself, with no guessing.
    mean = np.asarray(data["hands_mean"]).reshape(15, 3)
    axes = mean / np.maximum(np.linalg.norm(mean, axis=1, keepdims=True), 1e-9)
    return hand, axes


def pose(axes, bends, spread=None, normal=None):
    """Axis-angle for each joint from {joint: radians of curl}, negative to straighten past flat, plus
    {joint: radians} of sideways swing about the palm's normal."""
    p = np.zeros((15, 3))
    for joint, angle in bends.items():
        p[joint] += axes[joint] * angle
    for joint, angle in (spread or {}).items():
        p[joint] += normal * angle
    return torch.tensor(p.reshape(1, 45), dtype=torch.float32)


def run(hand, hand_pose):
    out = hand(hand_pose=hand_pose, global_orient=torch.zeros(1, 3), betas=torch.zeros(1, 10))
    return out.vertices[0].detach().numpy().astype(np.float64), out.joints[0].detach().numpy().astype(np.float64)


def lower_bends(t):
    """The hand on the chest: fingers straight, then lifted off the chest at the knuckles."""
    bends = {}
    for knuckle, middle, tip in FINGERS:
        bends[knuckle] = -0.38 * t
        bends[middle] = 0.12 * t
        bends[tip] = 0.06 * t
    # The thumb is set apart, by `rest_thumb`, so it stays on the chest the whole time.
    return bends


# MANO joints in the 16-joint output that move the thumb, for finding its vertices.
THUMB_JOINTS = (13, 14, 15)


def rest_thumb(hand, axes, normal, base, place, lift):
    """A thumb pose that lies on the chest: MANO's relaxed thumb hangs below the palm and would sink
    into it. Searched over how far the thumb bends and swings, keeping the smallest change that
    leaves every thumb point at least 3 mm above the chest."""
    thumb = np.isin(np.asarray(hand.lbs_weights.argmax(dim=1)), THUMB_JOINTS)
    best = None
    for bend in np.linspace(-0.6, 0.5, 12):
        for swing in np.linspace(-0.7, 0.7, 15):
            bends = dict(base)
            bends[THUMB[0]] = bends.get(THUMB[0], 0) + bend
            bends[THUMB[1]] = bends.get(THUMB[1], 0) + bend * 0.5
            vertices, _ = run(hand, pose(axes, bends, {THUMB[0]: swing}, normal))
            low = (place(vertices)[thumb, 1] + lift).min()
            sunk = max(0.0, 0.003 - low)
            cost = sunk * 100 + abs(bend) * 0.01 + abs(swing) * 0.01
            if best is None or cost < best[0]:
                best = (cost, bend, swing, low)
    _, bend, swing, low = best
    return {THUMB[0]: bend, THUMB[1]: bend * 0.5}, {THUMB[0]: swing}, low


def upper_bends(t):
    """The hand on top: its fingers curl down through the lower hand's gaps and under its fingers."""
    bends = {}
    for knuckle, middle, tip in FINGERS:
        bends[knuckle] = 1.15 * t
        bends[middle] = 1.1 * t
        bends[tip] = 0.55 * t
    bends[THUMB[0]] = 0.35 * t
    bends[THUMB[1]] = 0.45 * t
    bends[THUMB[2]] = 0.3 * t
    return bends


# --- Into the app's hand space -------------------------------------------------------------------


def frame(joints, flex):
    """A rotation taking the hand's own axes to the app's: fingers to -z, palm to -y.

    `flex` is where the fingertips go as the hand closes, which says which side the palm is on."""
    fingers = joints[MIDDLE_KNUCKLE] - joints[WRIST]
    fingers /= np.linalg.norm(fingers)
    across = joints[INDEX_KNUCKLE] - joints[LITTLE_KNUCKLE]
    palm = np.cross(across, fingers)
    palm -= fingers * palm.dot(fingers)
    palm /= np.linalg.norm(palm)
    if palm.dot(flex) < 0:
        palm = -palm
    side = np.cross(palm, fingers)
    source = np.stack([fingers, palm, side])
    target = np.stack([[0, 0, -1.0], [0, -1.0, 0], np.cross([0, -1.0, 0], [0, 0, -1.0])])
    return target.T @ source


def placed(vertices, rotation, heel):
    return (vertices - heel) @ rotation.T


# Joint ids in MANO's 16-joint output, per finger: knuckle and the joint after it.
KNUCKLES = {"index": (1, 2), "middle": (4, 5), "ring": (10, 11), "little": (7, 8)}
# Pose ids of each finger's knuckle, in the same finger order.
POSE_KNUCKLE = {"index": INDEX[0], "middle": MIDDLE[0], "ring": RING[0], "little": LITTLE[0]}
ORDER = ("index", "middle", "ring", "little")
# How far the lower hand's fingers swing apart to open gaps for the upper hand's, in radians, away
# from the middle of the hand.
LOWER_SPREAD = {"index": 0.2, "middle": 0.07, "ring": -0.07, "little": -0.2}


def lanes(joints):
    """Each finger's x a third of the way out its first bone: where the other hand's fingers pass."""
    return {f: joints[a][0] + (joints[b][0] - joints[a][0]) / 3 for f, (a, b) in KNUCKLES.items()}


def build(folder, scratch):
    left, left_axes = model(folder, "LEFT", scratch)
    right, right_axes = model(folder, "RIGHT", scratch)

    # Each hand's frame from its flat pose, with the palm side from how its fingertips close.
    hands = {"lower": (left, left_axes), "upper": (right, right_axes)}
    frames, normals, outward = {}, {}, {}
    for name, (hand, axes) in hands.items():
        flat_v, flat_j = run(hand, pose(axes, {}))
        closed_v, _ = run(hand, pose(axes, {j: 0.8 for f in FINGERS for j in f}))
        rotation = frame(flat_j, (closed_v - flat_v).mean(axis=0))
        heel = flat_j[WRIST] + 0.25 * (flat_j[MIDDLE_KNUCKLE] - flat_j[WRIST])
        frames[name] = (rotation, heel)
        # The palm's normal in the model's own axes swings a finger sideways. Which way is +x in the
        # app's space, found by trying it.
        normals[name] = rotation.T @ np.array([0, -1.0, 0])
        _, swung = run(hand, pose(axes, {}, {INDEX[0]: 0.2}, normals[name]))
        moved = placed(swung, rotation, heel)[KNUCKLES["index"][1]][0] - placed(flat_j, rotation, heel)[KNUCKLES["index"][1]][0]
        outward[name] = 1.0 if moved > 0 else -1.0

    thumb_bend, thumb_swing = {}, {}

    def lower_pose(t):
        spread = {POSE_KNUCKLE[f]: outward["lower"] * a * t for f, a in LOWER_SPREAD.items()}
        spread.update({j: spread.get(j, 0) + a for j, a in thumb_swing.items()})
        bends = lower_bends(t)
        bends.update({j: bends.get(j, 0) + a for j, a in thumb_bend.items()})
        return pose(left_axes, bends, spread, normals["lower"])

    lower_v, lower_j = run(left, lower_pose(1.0))
    lower_v, lower_j = (placed(x, *frames["lower"]) for x in (lower_v, lower_j))
    # The heel of the palm on the chest. Not the lowest point overall: MANO's relaxed thumb hangs
    # below the palm, and resting on it would float the whole stack.
    knuckle_z = lambda j: np.mean([j[a][2] for a, _ in KNUCKLES.values()])
    heel_band = (lower_v[:, 2] > knuckle_z(lower_j) + 0.015) & (lower_v[:, 2] < lower_j[WRIST][2] - 0.015)
    heel_band &= np.asarray(left.lbs_weights.argmax(dim=1)) == WRIST
    lift = -lower_v[heel_band, 1].min()
    # One thumb pose for every step, open hand to grip, so it never dips in partway through. What the
    # thumb's fleshy base still sinks, no bend can lift, so the whole hand rises by that much.
    place_lower = lambda v: placed(v, *frames["lower"])
    bend, swing, _ = rest_thumb(left, left_axes, normals["lower"], lower_bends(1.0), place_lower, lift)
    thumb_bend.update(bend)
    thumb_swing.update(swing)
    thumb = np.isin(np.asarray(left.lbs_weights.argmax(dim=1)), THUMB_JOINTS)
    lowest = min((place_lower(run(left, lower_pose(t))[0])[thumb, 1] + lift).min() for t in (0.0, 0.5, 1.0))
    lift += max(0.0, 0.003 - lowest)
    print(f"[mano] lower thumb bent {bend[THUMB[0]]:.2f}, swung {swing[THUMB[0]]:.2f}; hand raised {max(0.0, 0.003 - lowest) * 1000:.1f} mm to keep it on the chest")

    # The gaps the lower hand's fingers leave, in order across, and one more past its little finger.
    low = lanes(lower_j)
    xs = sorted(low.values())
    spacing = float(np.mean(np.diff(xs)))
    gaps = [(a + b) / 2 for a, b in zip(xs, xs[1:])]
    # The upper hand is a right hand, so its fingers run the other way across; four fingers take the
    # three gaps and one lane outside, whichever side needs the smaller move.
    _, up_flat_j = run(right, pose(right_axes, {}))
    up_lanes = lanes(placed(up_flat_j, *frames["upper"]))
    up_xs = [up_lanes[f] for f in sorted(ORDER, key=lambda f: up_lanes[f])]
    options = [[xs[0] - spacing / 2] + gaps, gaps + [xs[-1] + spacing / 2]]
    # The hands stay stacked, so the smaller sideways move wins, with an uneven fit as a tiebreak.
    targets = min(options, key=lambda lane: abs(np.mean(np.array(lane) - np.array(up_xs))) + np.std(np.array(lane) - np.array(up_xs)))
    shift_x = float(np.mean(np.array(targets) - np.array(up_xs)))
    # What the shift can't fix, each finger swings to. A first bone is about 4.5 cm.
    bone = 0.045
    residual = {f: t - (x + shift_x) for f, x, t in zip(sorted(ORDER, key=lambda f: up_lanes[f]), up_xs, targets)}

    def upper_pose(t):
        spread = {POSE_KNUCKLE[f]: outward["upper"] * np.arcsin(np.clip(r / bone, -0.5, 0.5)) * t for f, r in residual.items()}
        return pose(right_axes, upper_bends(t), spread, normals["upper"])

    upper_v, upper_j = run(right, upper_pose(1.0))
    upper_v, upper_j = (placed(x, *frames["upper"]) for x in (upper_v, upper_j))
    # Knuckle over knuckle, a little toward the wrist, so the fingers drop in at the base of the gaps.
    shift_z = knuckle_z(lower_j) + 0.006 - knuckle_z(upper_j)
    offset = np.array([shift_x, 0.0, shift_z])

    # Palm against palm: only the parts each hand's wrist moves, so the lower hand's lifted fingers
    # and the upper hand's curled ones don't hold the hands apart.
    lower_final = lower_v + [0, lift, 0]
    # The back of the lower hand only, behind its knuckles: lifting its fingers raises the knuckle
    # ridge, and the upper palm rests on the flat behind it in a real grip, not on the ridge.
    # MANO's hands carry a thick stub of wrist behind the palm, which would prop the hands apart, so
    # both are measured only between the knuckles and the wrist.
    band = (knuckle_z(lower_j) + 0.015, lower_j[WRIST][2] - 0.015)
    lower_palm = (np.asarray(left.lbs_weights.argmax(dim=1)) == WRIST) & (lower_final[:, 2] > band[0]) & (lower_final[:, 2] < band[1])
    upper_moved = upper_v + offset
    upper_palm = (np.asarray(right.lbs_weights.argmax(dim=1)) == WRIST) & (upper_moved[:, 2] > band[0]) & (upper_moved[:, 2] < band[1])
    raise_by = -1.0
    for v in upper_v[upper_palm] + offset:
        near = np.linalg.norm(lower_final[lower_palm][:, [0, 2]] - v[[0, 2]], axis=1) < 0.006
        if near.any():
            raise_by = max(raise_by, lower_final[lower_palm][near, 1].max() - v[1] + 0.001)
    offset = offset + [0, raise_by, 0]
    print(f"[mano] upper hand resting {raise_by:.3f} m up, knuckles {shift_z:.3f} m along")

    lower_frames, upper_frames = [], []
    for t in np.linspace(0, 1, STEPS):
        lower_frames.append(placed(run(left, lower_pose(t))[0], *frames["lower"]) + [0, lift, 0])
        upper_frames.append(placed(run(right, upper_pose(t))[0], *frames["upper"]) + offset)

    report(lower_frames[-1], upper_frames[-1], left, right, targets, shift_x, residual)
    return {
        "lower_faces": np.asarray(left.faces, dtype=np.int32),
        "upper_faces": np.asarray(right.faces, dtype=np.int32),
        "lower_frames": np.asarray(lower_frames, dtype=np.float32),
        "upper_frames": np.asarray(upper_frames, dtype=np.float32),
    }


def report(lower, upper, left, right, targets, shift_x, residual):
    """How well the grip interlocks: upper fingertips below the tops of the lower fingers, and how
    close the two hands' fingers come."""
    lower_fingers = np.asarray(left.lbs_weights.argmax(dim=1)) != WRIST
    upper_fingers = np.asarray(right.lbs_weights.argmax(dim=1)) != WRIST
    gaps = np.linalg.norm(upper[upper_fingers][:, None, :] - lower[lower_fingers][None, :, :], axis=2).min(axis=1)
    print(f"[mano] lanes {np.round(targets, 3)}, shift {shift_x:.3f} m, swings {[round(r, 4) for r in residual.values()]}")
    print(f"[mano] upper finger points within 2 mm of a lower finger: {np.mean(gaps < 0.002):.0%}, "
          f"lowest upper point y {upper[upper_fingers][:, 1].min():.3f}, top of lower fingers y {lower[lower_fingers][:, 1].max():.3f}")


def main():
    folder = Path(sys.argv[1]).expanduser()
    out = Path(sys.argv[2]).expanduser()
    # The official zip has the pickles under mano_v1_2/models.
    found = next((p.parent for p in folder.rglob("MANO_RIGHT.pkl")), None)
    if found is None:
        sys.exit(f"No MANO_RIGHT.pkl under {folder}. Download it from https://mano.is.tue.mpg.de")
    scratch = out.parent
    data = build(found, scratch)
    np.savez(out, **data)
    for name in ("lower", "upper"):
        f = data[f"{name}_frames"][-1]
        print(f"[mano] {name}: {f.shape[0]} vertices, x {f[:, 0].min():.3f}..{f[:, 0].max():.3f}, "
              f"y {f[:, 1].min():.3f}..{f[:, 1].max():.3f}, z {f[:, 2].min():.3f}..{f[:, 2].max():.3f}")
    print(f"[mano] wrote {out}")


if __name__ == "__main__":
    main()

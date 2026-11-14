#!/bin/zsh
# Fine-tune PP-OCRv6 small on a build_train.py data folder, then export an inference model.
# usage: train_chords.sh DATA_DIR OUT_DIR [EPOCHS] [extra -o overrides...]
# Needs data/tools/PaddleOCR (git clone), data/tools/trainenv (paddlepaddle + its requirements) and
# data/tools/weights/PP-OCRv6_small_rec_pretrained.pdparams (see README).
set -e
here=${0:A:h}
T=$here/data/tools
data=${1:A}; out=${2:A}; epochs=${3:-1}; shift 3 2>/dev/null || shift $#
mkdir -p $out
sed -e "s#OUT#$out#" -e "s#WEIGHTS#$T/weights/PP-OCRv6_small_rec_pretrained#" -e "s#DATA#$data#g" \
    $here/chord_rec.yml > $out/config.yml
cd $T/PaddleOCR
$T/trainenv/bin/python tools/train.py -c $out/config.yml -o Global.epoch_num=$epochs "$@" 2>&1 | tee $out/train.log
best=$out/best_accuracy; [ -f $best.pdparams ] || best=$out/latest
$T/trainenv/bin/python tools/export_model.py -c $out/config.yml \
    -o Global.pretrained_model=$best Global.save_inference_dir=$out/infer 2>&1 | tail -3

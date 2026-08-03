export const reactionDirections = Object.freeze({
  received: "认真点头或敬礼，明确表达已经收到信息",
  okay: "友好微笑并比出 OK 手势",
  laughing: "闭眼大笑、笑出眼泪，身体开心后仰",
  speechless: "半眯眼侧目，双手抱胸，表现无奈和无语",
  shocked: "睁大眼睛张开嘴，身体明显后缩",
  angry: "皱眉鼓脸、握拳，表现明确但不暴力的生气",
  wronged: "眼含泪光、低头抿嘴，表现委屈和需要安慰",
  refuse: "双臂交叉并摇头，明确表达不要",
  please: "双手合十、期待泪眼，表现真诚恳求",
  thanks: "微笑鞠躬，双手送出爱心表达感谢",
  onTheWay: "背着小包向前快跑，带清楚的速度感",
  goodNight: "抱着枕头或裹着被子安静入睡",
});

export function buildStickerPrompt(reactionId) {
  const direction = reactionDirections[reactionId];
  if (!direction) {
    throw new Error("未知的聊天意图");
  }

  return [
    "参考所有输入照片中的同一个主体，保持可辨认的脸型、发型、五官、眼镜或配饰、服装主色等身份特征。",
    "多张照片视为同一人的互补参考：以正常拍摄距离、自然透视的照片确定脸部和身体比例，近距离自拍只用于补充五官、发型、眼镜等细节。",
    "把主体绘制成高相似度、精致、统一画风的 Q 版聊天贴纸角色，头身比例约 2:1；保留真实的脸部轮廓、五官间距和眼睛大小，不要变成通用大眼萌脸。",
    `这一张贴纸的表情和动作：${direction}。`,
    "画面只出现一个完整角色，居中构图，主体不要被裁切，使用无纹理、无渐变的纯白或纯色背景，柔和光线，清晰边缘。",
    "不要生成任何文字、字母、数字、对话框、水印、标志、边框或额外人物。",
  ].join("\n");
}

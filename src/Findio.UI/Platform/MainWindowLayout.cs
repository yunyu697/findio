namespace Findio.UI.Platform;

/// <summary>
/// 主搜索窗几何：宽度取工作区宽度的 40%，再夹在 600–880 DIP 之间；顶边固定在工作区高度 1/4 处，水平居中。
/// 计算顺序固定为「工作区物理宽 → 该屏 DIP → 乘 40% → 夹 DIP 上下限 → 乘回该屏 DPI 得物理像素」，
/// 这样夹值在每一档缩放都按同一套 DIP 规则生效，不会因为物理像素取整而在 125%/150% 下换档。
/// 调用方用 SetWindowPos 以物理像素落位，高度仍由 DIP 换算。
/// </summary>
internal static class MainWindowLayout
{
    /// <summary>宽度占工作区宽度的比例。</summary>
    public const double WidthFraction = 0.40;

    /// <summary>宽度下限（DIP）。不随缩放放大缩小。</summary>
    public const double MinWidthDip = 600;

    /// <summary>宽度上限（DIP）。不随缩放放大缩小。</summary>
    public const double MaxWidthDip = 880;

    /// <summary>顶边相对工作区高度的位置。</summary>
    public const double TopFraction = 0.25;

    public readonly record struct Frame(int X, int Y, int Width, int Height);

    /// <summary>
    /// 按工作区物理边界与目标缩放计算窗口矩形（物理像素）。
    /// </summary>
    /// <param name="workLeft">工作区左边（物理像素）。</param>
    /// <param name="workTop">工作区上边（物理像素）。</param>
    /// <param name="workRight">工作区右边（物理像素）。</param>
    /// <param name="workBottom">工作区下边（物理像素）。</param>
    /// <param name="scale">该显示器有效缩放（DPI / 96）。</param>
    /// <param name="heightDip">窗口高度（DIP），本次不改。</param>
    public static Frame Compute(int workLeft, int workTop, int workRight, int workBottom, double scale, double heightDip)
    {
        var lpWorkWidth = workRight - workLeft;
        var lpWorkHeight = workBottom - workTop;

        // 取整策略（有意混用，改动前先读这段）：
        // 1) 宽度先按该屏 DPI 把工作区物理宽换成 DIP：workWidthDip = workWidthPx / scale；
        // 2) targetDip = workWidthDip × 40%；clampDip = Clamp(targetDip, 600, 880)；
        // 3) widthPx = Round(clampDip × scale)。宽度取整只发生在最后一步，DIP 夹值不会因为
        //    125%/150%/175% 的换算而换档（直接对物理像素乘比例会出现这种换档）。
        // 4) 窄屏兜底：下限取 Min(600, workWidthDip)，保证工作区比 600 DIP 还窄时窗口不越界；
        //    工作区 DIP 宽 < 1200 时 40% 恒小于 600，因此一律按 600 处理（见 --layout-probe 的 narrowScreen）。
        // 高度仍按 DIP 换算（Round(heightDip × scale)）。
        // 宽高与 Y 用 Math.Round（默认 MidpointRounding.ToEven，银行家舍入）；X 用整数除法
        // （非负值即向下取整），保持左右留白完全对称。
        var lpWorkWidthDip = lpWorkWidth / scale;
        var lpTargetDip = lpWorkWidthDip * WidthFraction;
        var lpMinDip = Math.Min(MinWidthDip, lpWorkWidthDip);
        var lpClampDip = Math.Clamp(lpTargetDip, lpMinDip, MaxWidthDip);
        var lpWidth = (int)Math.Round(lpClampDip * scale);
        var lpHeight = (int)Math.Round(heightDip * scale);
        var lpX = workLeft + (lpWorkWidth - lpWidth) / 2;
        var lpY = workTop + (int)Math.Round(lpWorkHeight * TopFraction);
        return new Frame(lpX, lpY, lpWidth, lpHeight);
    }
}

#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "matplotlib",
# ]
# ///
"""Yield Tranche Vault — 자금 흐름도 (한국어)"""

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from matplotlib.font_manager import FontProperties
import os

# 한글 폰트 설정
font_paths = [
    os.path.expanduser('~/.local/share/fonts/NotoSansCJKkr-Regular.otf'),
    '/usr/share/fonts/truetype/nanum/NanumGothicBold.ttf',
    '/usr/share/fonts/truetype/nanum/NanumGothic.ttf',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
    '/usr/share/fonts/opentype/unifont/unifont.otf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
]
KR_FONT = None
for p in font_paths:
    if os.path.exists(p):
        KR_FONT = p
        break

matplotlib.rcParams['axes.unicode_minus'] = False
matplotlib.rcParams['text.usetex'] = False
matplotlib.rcParams['mathtext.default'] = 'regular'

fig, ax = plt.subplots(1, 1, figsize=(20, 30))
ax.set_xlim(0, 20)
ax.set_ylim(0, 30)
ax.axis('off')
fig.patch.set_facecolor('#0a0a0a')

# Colors
C_BG = '#0a0a0a'
C_FIXED = '#2196F3'
C_VARIABLE = '#FF5722'
C_LIDO = '#00bcd4'
C_MORPHO = '#7C4DFF'
C_LOOP = '#FF9800'
C_YIELD = '#4CAF50'
C_TEXT = '#EEEEEE'
C_GRAY = '#666666'
C_GOLD = '#FFD700'
C_RED = '#F44336'
C_VAULT_BORDER = '#4FC3F7'

fp = FontProperties(fname=KR_FONT) if KR_FONT else None

def txt(x, y, s, size=11, color=C_TEXT, bold=True, ha='center', va='center'):
    actual_size = size + (1 if bold else 0)
    # Always use FontProperties directly — rcParams doesn't work for CJK
    ax.text(x, y, s, ha=ha, va=va, fontsize=actual_size,
            color=color, zorder=5, fontproperties=fp)

def box(x, y, w, h, color, border=None, alpha=0.9):
    rect = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.15",
                           facecolor=color, edgecolor=border or color,
                           alpha=alpha, linewidth=2, zorder=3)
    ax.add_patch(rect)

def arrow(x1, y1, x2, y2, color='#AAAAAA', lw=2, style='->'):
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle=style, color=color, lw=lw), zorder=2)

def arrow_curved(x1, y1, x2, y2, color='#AAAAAA', lw=2, rad=0.3):
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle='->', color=color, lw=lw,
                                connectionstyle=f"arc3,rad={rad}"), zorder=2)

# ============================================================
# TITLE
# ============================================================
txt(10, 29.3, 'YIELD TRANCHE VAULT', 26, C_GOLD)
txt(10, 28.7, 'Correlated Pair Loop  |  자금 흐름도', 14, C_GRAY, bold=False)

# ============================================================
# 1. 사용자 입금
# ============================================================
box(7, 27, 6, 1.2, '#1565C0', border='#42A5F5')
txt(10, 27.7, '사용자', 16)
txt(10, 27.3, 'ETH 입금', 11, '#90CAF9', bold=False)

# 트랜치 선택 화살표
arrow(8.2, 27, 4.5, 26, C_FIXED, lw=2.5)
txt(5.8, 26.7, 'Fixed 선택', 9, C_FIXED)

arrow(11.8, 27, 15.5, 26, C_VARIABLE, lw=2.5)
txt(14.2, 26.7, 'Variable 선택', 9, C_VARIABLE)

# 트랜치 토큰
box(2, 25.1, 5, 1, C_FIXED, border='#64B5F6')
txt(4.5, 25.7, 'fToken (고정 수익)', 11)
txt(4.5, 25.3, '목표 3~5% APR', 9, '#90CAF9', bold=False)

box(13, 25.1, 5, 1, C_VARIABLE, border='#FF8A65')
txt(15.5, 25.7, 'vToken (변동 수익)', 11)
txt(15.5, 25.3, '레버리지 초과수익', 9, '#FFAB91', bold=False)

# ============================================================
# 2. 볼트 (메인 박스)
# ============================================================
vault = FancyBboxPatch((1, 5.5), 18, 18.5, boxstyle="round,pad=0.3",
                        facecolor='#1a1a2e', edgecolor=C_VAULT_BORDER,
                        alpha=0.4, linewidth=2.5, linestyle='--', zorder=1)
ax.add_patch(vault)
txt(10, 23.5, 'TrancheVault.sol', 13, C_VAULT_BORDER, bold=False)

# ============================================================
# 3. ETH → stETH 래핑
# ============================================================
arrow(10, 27, 10, 22.5, '#4FC3F7', lw=3)
txt(10.8, 24.5, 'ETH', 10, '#4FC3F7')

box(7, 21.5, 6, 1, C_LIDO)
txt(10, 22.1, 'Lido', 14)
txt(10, 21.7, 'ETH → stETH 래핑', 10, '#80DEEA', bold=False)

# ============================================================
# 4. 분배: 90% 루프, 10% Morpho 공급
# ============================================================
arrow(8, 21.5, 5.5, 20.2, C_LOOP, lw=2.5)
txt(6.2, 21, '90%', 10, C_LOOP)

arrow(12, 21.5, 14.5, 20.2, C_MORPHO, lw=2)
txt(13.8, 21, '10%', 10, C_MORPHO)

# Morpho Supply
box(12.5, 19.2, 5.5, 1, C_MORPHO)
txt(15.25, 19.8, 'Morpho 공급', 12)
txt(15.25, 19.4, '유휴 stETH 예치 → 1.5% APR', 9, '#CE93D8', bold=False)

# ============================================================
# 5. 루프 엔진 (왼쪽, 상세)
# ============================================================
loop_bg = FancyBboxPatch((1.5, 10.2), 9.5, 9.5, boxstyle="round,pad=0.2",
                          facecolor='#1a1200', edgecolor=C_LOOP,
                          alpha=0.3, linewidth=2, linestyle=':', zorder=1)
ax.add_patch(loop_bg)
txt(6.25, 19.3, 'LoopEngine.sol — 재귀 레버리지 x3~4', 11, C_LOOP)

# Step 1
box(2, 17.2, 4.5, 1, '#33691E', border='#66BB6A')
txt(4.25, 17.8, '① stETH 담보 예치', 10)
txt(4.25, 17.4, 'Morpho Blue에 담보로 넣기', 8, '#A5D6A7', bold=False)

# Step 2
arrow(6.5, 17.7, 7.5, 17.7, C_LOOP, lw=2)
box(7.5, 17.2, 3.5, 1, '#BF360C', border='#FF7043')
txt(9.25, 17.8, '② ETH 차입', 10)
txt(9.25, 17.4, '금리 ~1.5% APR', 8, '#FFAB91', bold=False)

# Step 3
arrow(9.25, 17.2, 9.25, 16.1, C_LIDO, lw=2)
box(7, 15.2, 4.5, 0.9, C_LIDO)
txt(9.25, 15.7, '③ ETH → stETH 변환', 10)

# Step 4: loop back
arrow(7, 15.6, 2.5, 15.6, C_LOOP, lw=2)
arrow(2.5, 15.6, 2.5, 17.2, C_LOOP, lw=2)
txt(2.2, 16.4, '반복\nx3~4', 9, C_LOOP)

# 결과 박스
box(2, 12.2, 9, 2.2, '#1B5E20', border=C_YIELD, alpha=0.5)
txt(6.5, 13.9, '$100 ETH 입금 → $360 stETH 노출', 12, C_YIELD)
txt(6.5, 13.3, '$260 ETH 부채  |  3.6배 레버리지', 11, '#A5D6A7')
txt(6.5, 12.7, 'LTV 리스크: stETH/ETH 디페그만 (ETH 가격 무관)', 9, '#FFF59D', bold=False)

# 수익 계산
txt(3, 11.5, 'stETH 수익 3.0% x $360 = $10.80', 9, C_YIELD, ha='left')
txt(3, 11.1, 'ETH 차입비용 1.5% x $260 = -$3.90', 9, C_RED, ha='left')
txt(3, 10.6, '순 레버리지 수익 = +$6.90 (+6.9%)', 10, C_GOLD, ha='left')

# ============================================================
# 6. 디레버리지 모니터 (오른쪽)
# ============================================================
box(12.5, 14, 5.5, 3.5, '#311B92', border='#B388FF', alpha=0.5)
txt(15.25, 17.1, 'Deleverage.sol', 11, '#B388FF')
txt(15.25, 16.5, 'stETH/ETH 페그 모니터링', 9, '#CE93D8', bold=False)
txt(15.25, 15.8, 'peg > 0.995: 정상', 9, C_YIELD)
txt(15.25, 15.3, 'peg < 0.985: 디레버리지', 9, C_LOOP)
txt(15.25, 14.8, 'peg < 0.960: 긴급 해제', 9, C_RED)
txt(15.25, 14.3, 'ETH 가격 하락은 영향 없음!', 9, '#FFF59D', bold=False)

arrow_curved(10.5, 13, 12.5, 15, '#B388FF', lw=1.5, rad=0.3)

# ============================================================
# 7. 총 수익 집계
# ============================================================
arrow(6.5, 10.2, 6.5, 9.3, C_YIELD, lw=2.5)
arrow(15.25, 19.2, 15.25, 9.3, C_YIELD, lw=2)
txt(16, 14, '+1.5%', 9, C_YIELD)

box(3, 8.3, 14, 1, '#1B5E20', border=C_YIELD, alpha=0.7)
txt(10, 8.9, '총 수익률: ~7.2% APR', 15, C_YIELD)
txt(10, 8.5, 'stETH 3% x 3.6배 + Morpho 1.5% x 10% - 차입비용 - 수수료', 9, '#A5D6A7', bold=False)

# ============================================================
# 8. 워터폴 분배
# ============================================================
arrow(10, 8.3, 10, 7.6, C_GOLD, lw=2.5)
txt(10, 7.3, 'EpochSettlement.sol (주간 워터폴 분배)', 11, C_GOLD)

# Fixed 우선
arrow(7, 7, 4, 6.5, C_FIXED, lw=2.5)
txt(5, 6.9, '1순위', 9, C_FIXED)

box(1.5, 5.7, 5, 0.8, C_FIXED, border='#64B5F6', alpha=0.8)
txt(4, 6.2, '고정 트랜치: 3~5% APR', 11)

# Variable 나머지
arrow(13, 7, 16, 6.5, C_VARIABLE, lw=2.5)
txt(15, 6.9, '나머지 전부', 9, C_VARIABLE)

box(13.5, 5.7, 5, 0.8, C_VARIABLE, border='#FF8A65', alpha=0.8)
txt(16, 6.2, '변동 트랜치: 10~14% APR', 11)

# Reserve
arrow(10, 7, 10, 6.5, '#8BC34A', lw=1.5)
txt(10, 6.85, '2% 적립', 8, '#8BC34A')

box(8, 5.7, 4, 0.8, '#33691E', border='#8BC34A', alpha=0.7)
txt(10, 6.2, '리저브 버퍼', 10)

# ============================================================
# 9. 핵심 인사이트
# ============================================================
insight = FancyBboxPatch((1, 0.5), 18, 4.5, boxstyle="round,pad=0.3",
                          facecolor='#1a1a00', edgecolor=C_GOLD,
                          alpha=0.4, linewidth=2, zorder=1)
ax.add_patch(insight)
txt(10, 4.6, 'Correlated Pair Loop이 작동하는 이유', 14, C_GOLD)

data = [
    ('ETH 차입 (USDC 아님):', '금리 1.5% vs 4~10% → 스프레드 항상 양수', C_YIELD),
    ('ETH 가격 하락 시:', '담보·부채 모두 ETH 기반 → LTV 변화 없음', '#4FC3F7'),
    ('유일한 리스크:', 'stETH/ETH 디페그 (역사적 최대 3~5%, 매우 드뭄)', C_LOOP),
    ('결과:', '$100 입금 → 7.2% APR, 고정 트랜치 100% 보장', C_GOLD),
]
for i, (k, v, c) in enumerate(data):
    y = 3.8 - i * 0.6
    txt(3, y, k, 11, c, ha='left')
    txt(9, y, v, 10, '#CCCCCC', bold=False, ha='left')

# ============================================================
# SAVE
# ============================================================
out = '/home/jj/yield-tranche-vault/backtest/output/money_flow_kr.png'
plt.savefig(out, dpi=150, bbox_inches='tight', facecolor=C_BG)
plt.close()
print(f"Done → {out}")

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
import zipfile
root=Path(__file__).parent/'fixtures'; root.mkdir(exist_ok=True)
fontpath='/System/Library/Fonts/Supplemental/Arial.ttf'
font=lambda n:ImageFont.truetype(fontpath,n)
im=Image.new('RGB',(900,560),'white'); d=ImageDraw.Draw(im)
d.text((60,20),'Growth in common stocks',font=font(40),fill='#172b4d')
for y in range(120,501,95):
 d.line([(90,y),(830,y)],fill='#d8dee7',width=2)
 d.text((25,y-12),str(500-y),font=font(22),fill='#526075')
d.line([(90,100),(90,500),(830,500)],fill='#526075',width=3)
points=[(90,480),(160,435),(240,456),(320,350),(400,360),(480,290),(560,320),(640,215),(720,190),(810,110)]
d.line(points,fill='#127cbb',width=9)
d.text((95,520),'Illustration preservation - synthetic sample',font=font(22),fill='#526075')
im.save(root/'chart.png')
body="""<h2>Illustration preservation</h2><p>Table 1-1. AVERAGE ANNUAL RETURN</p>
<table><tr><th>Asset</th><th>1920s</th><th>1930s</th></tr><tr><td>Stocks</td><td>19.2%</td><td>0.0%</td></tr><tr><td>Bonds</td><td>5.0%</td><td>4.9%</td></tr></table>
<p><img src='../Images/chart.png' alt=''/></p><p>FIGURE 1-1</p>
<p>CheckpointDestination the table and chart remain visible while listening.</p>
<p>Vector chart</p><svg viewBox='0 0 900 560'><image href='../Images/chart.png' width='900' height='560'/></svg>
<p>Repeated illustration</p><figure><img src='../Images/chart.png'/><img src='../Images/chart.png'/></figure>"""
with zipfile.ZipFile(root/'illustrations.epub','w',zipfile.ZIP_DEFLATED) as z:
 z.writestr('mimetype','application/epub+zip')
 z.writestr('META-INF/container.xml',"<container><rootfiles><rootfile full-path='OEBPS/content.opf'/></rootfiles></container>")
 z.writestr('OEBPS/content.opf',"<package><metadata><title>Illustration preservation</title></metadata><manifest><item id='c' href='Text/chapter.xhtml' media-type='application/xhtml+xml'/><item id='i' href='Images/chart.png' media-type='image/png'/></manifest><spine><itemref idref='c'/></spine></package>")
 z.writestr('OEBPS/Text/chapter.xhtml','<html><body>'+body+'</body></html>')
 z.write(root/'chart.png','OEBPS/Images/chart.png')
pdf=canvas.Canvas(str(root/'mixed-illustrations.pdf'),pagesize=(400,600))
pdf.drawImage(str(root/'chart.png'),30,205,340,212);pdf.showPage()
pdf.setFont('Helvetica-Bold',18);pdf.drawString(30,550,'Searchable chapter')
pdf.setFont('Helvetica',12);pdf.drawString(30,521,'Original typography and the chart stay together.')
pdf.drawImage(str(root/'chart.png'),30,190,340,212);pdf.drawString(30,164,'FIGURE 1-1');pdf.showPage()
scan=Image.new('RGB',(1200,1800),'white'); ds=ImageDraw.Draw(scan)
ds.text((90,110),'Scanned chapter',font=font(54),fill='#172b4d')
for y,t in [(240,'CheckpointDestination the chart remains'),(315,'on the original page.'),(420,'The voice follows the printed words.')]:ds.text((90,y),t,font=font(46),fill='black')
scan.paste(im.resize((1020,635)),(90,870));scan.save(root/'scanned-page.png')
pdf.drawImage(ImageReader(scan),0,0,400,600);pdf.showPage();pdf.showPage();pdf.save()
print(root)

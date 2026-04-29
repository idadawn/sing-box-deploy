// v2rayN 订阅接口 - 返回 Base64 编码的 URI 列表
export async function onRequest(context) {
  const url = new URL(context.request.url);
  const isRaw = url.searchParams.get('raw') === '1';

  const nodes = [
    `trojan://N4ECmnqD7FYVtLGEjaiNjPRdsq%2BN4IPiGsMk2Lr%2BTeE%3D@trojan.1761.org:14687?security=tls&sni=trojan.1761.org&alpn=h2%2Chttp%2F1.1&fp=chrome#ISP-1-TJ`,
    `hysteria2://lto9Q49Yfn0mfMM9%2BrxrPcbQYreT4KmC9rMSmhABMSc%3D@hy2.1761.org:19623/?sni=hy2.1761.org&obfs=salamander&obfs-password=PGZB1uQKemx27ILXlKab8INNTClMW8W1&insecure=0#ISP-1-HY2`,
  ];

  if (true) {
    nodes.push(
      `trojan://N4ECmnqD7FYVtLGEjaiNjPRdsq%2BN4IPiGsMk2Lr%2BTeE%3D@trojan.1761.org:24687?security=tls&sni=trojan.1761.org&alpn=h2%2Chttp%2F1.1&fp=chrome#ISP-2-TJ`,
      `hysteria2://lto9Q49Yfn0mfMM9%2BrxrPcbQYreT4KmC9rMSmhABMSc%3D@hy2.1761.org:29623/?sni=hy2.1761.org&obfs=salamander&obfs-password=PGZB1uQKemx27ILXlKab8INNTClMW8W1&insecure=0#ISP-2-HY2`,
    );
  }

  nodes.push(
    `trojan://N4ECmnqD7FYVtLGEjaiNjPRdsq%2BN4IPiGsMk2Lr%2BTeE%3D@trojan.1761.org:34687?security=tls&sni=trojan.1761.org&alpn=h2%2Chttp%2F1.1&fp=chrome#VPS-TJ`,
    `hysteria2://lto9Q49Yfn0mfMM9%2BrxrPcbQYreT4KmC9rMSmhABMSc%3D@hy2.1761.org:39623/?sni=hy2.1761.org&obfs=salamander&obfs-password=PGZB1uQKemx27ILXlKab8INNTClMW8W1&insecure=0#VPS-HY2`,
  );

  const uriList = nodes.join('\n');

  if (isRaw) {
    return new Response(uriList, {
      status: 200,
      headers: { 
        'Content-Type': 'text/plain; charset=utf-8', 
        'Cache-Control': 'no-cache', 
        'Access-Control-Allow-Origin': '*'
      }
    });
  }

  const encoder = new TextEncoder();
  const data = encoder.encode(uriList);
  const base64Config = btoa(String.fromCharCode(...data));
  
  return new Response(base64Config, {
    status: 200,
    headers: { 
      'Content-Type': 'text/plain; charset=utf-8', 
      'Cache-Control': 'no-cache', 
      'Access-Control-Allow-Origin': '*',
      'Subscription-Userinfo': 'upload=0; download=0; total=0; expire=0'
    }
  });
}

import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import rehypeExternalLinks from 'rehype-external-links';
import { targetBlank } from './src/plugins/targetBlank';

// https://astro.build/config
export default defineConfig({
	site: 'https://darkone-linux.github.io',
	trailingSlash: "always",
	build: {
		assets: 'astro',
	},
	markdown: {
		rehypePlugins: [
			[targetBlank, { domain: 'darkone-linux.github.io' }],
			[
				rehypeExternalLinks,
				{
				  content: { type: 'text', value: '\u{00A0}\u{1F855}' }
				}
			],
		],
	},
	integrations: [
		starlight({
			title: "Darkone NixOS Framework",
			favicon: '/favicon.svg',
			customCss: [
				'./src/styles/custom.css',
			],
			locales: {
				root: {
						label: 'English',
						lang: 'en-US',
				},
			},
			social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/darkone-linux/darkone-nixos-framework' },
      ],
			logo: {
				src: './src/assets/nix-logo.svg',
			},
			sidebar: [
				{
					label: 'Documentation',
					autogenerate: { directory: 'doc' },
				},
				{
					label: 'References',
					autogenerate: { directory: 'ref' },
				},
				{ label: 'Changelog', slug: 'changelog' },
				{ label: 'Thanks!', slug: 'thanks' },
			],
		}),
	],
});
